#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# shellcheck disable=SC2016  # backticks in --query strings are JMESPath literals
# Optional CLI shortcut for the console steps in README.md.
# Usage:
#   ./deploy.sh upload <bucket>                               # copy this kit to s3://<bucket>/$PREFIX
#   ./deploy.sh shared <bucket> <admin-email> [Key=Value ...] # deploy infra/shared.yaml (once per account/region)
#   ./deploy.sh box <owner> [Key=Value ...]                   # deploy box/box.yaml for one user
#   ./deploy.sh connect <owner> | status | delete-box <owner>
#   ./deploy.sh doctor <owner>                                # why a box failed or can't be reached (read-only)
#   ./deploy.sh grafana-setup                                 # Athena plugin, data source and dashboards in the
#                                                             # shared stack's Grafana workspace (ConfigureAnalytics)
# Key=Value pairs are extra stack parameters, e.g. CreateNetwork=No ExistingVpcId=vpc-... or
#   AuthMode=IamUser (shared) or InstanceType=t3.2xlarge Toolchains=python,node (box)
# Env: AWS_PROFILE, AWS_REGION, SHARED_STACK (default claude-scan-shared), PREFIX (default claude-scan-kit/)
set -euo pipefail

SHARED_STACK="${SHARED_STACK:-claude-scan-shared}"
PREFIX="${PREFIX:-claude-scan-kit/}"
DIR="$(cd "$(dirname "$0")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }
box_stack() { echo "claude-scan-box-$1"; }
output() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

case "${1:-}" in
  upload)
    [[ -n ${2:-} ]] || die "usage: $0 upload <bucket>"
    aws s3 sync "$DIR" "s3://$2/$PREFIX" --delete --exclude '.*' --exclude '*/.*' --exclude 'policies/out/*'
    echo "Uploaded. shared.yaml URL: https://$2.s3.${AWS_REGION:-<region>}.amazonaws.com/${PREFIX}infra/shared.yaml" ;;
  shared)
    [[ -n ${2:-} && -n ${3:-} ]] || die "usage: $0 shared <bucket> <admin-email> [Key=Value ...]"
    bucket=$2 email=$3; shift 3
    aws cloudformation deploy --stack-name "$SHARED_STACK" --template-file "$DIR/infra/shared.yaml" \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --no-fail-on-empty-changeset \
      --parameter-overrides ArtifactBucket="$bucket" ArtifactPrefix="$PREFIX" AdminEmail="$email" "$@"
    echo "Confirm the SNS subscription email sent to $email." ;;
  box)
    [[ -n ${2:-} ]] || die "usage: $0 box <owner> [Key=Value ...]"
    owner=$2; shift 2
    aws cloudformation deploy --stack-name "$(box_stack "$owner")" --template-file "$DIR/box/box.yaml" \
      --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
      --parameter-overrides SharedStackName="$SHARED_STACK" Owner="$owner" "$@"
    aws cloudformation describe-stacks --stack-name "$(box_stack "$owner")" --query 'Stacks[0].Outputs' --output table ;;
  connect)
    [[ -n ${2:-} ]] || die "usage: $0 connect <owner>"
    aws ssm start-session --target "$(output "$(box_stack "$2")" InstanceId)" ;;
  status)
    aws cloudformation describe-stacks --query \
      "Stacks[?starts_with(StackName,'claude-scan-')].[StackName,StackStatus]" --output table ;;
  doctor)
    [[ -n ${2:-} ]] || die "usage: $0 doctor <owner>"
    stack=$(box_stack "$2")
    echo "== Box stack $stack"
    aws cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].[StackStatus,StackStatusReason]' --output text || exit 1
    aws cloudformation describe-stack-events --stack-name "$stack" --max-items 100 \
      --query "StackEvents[?contains(ResourceStatus,'FAILED')] | [0:3].[Timestamp,LogicalResourceId,ResourceStatusReason]" --output text
    group=$(output "$SHARED_STACK" HeartbeatLogGroup)
    stream=$(aws logs describe-log-streams --log-group-name "$group" --log-stream-name-prefix bootstrap-failure \
      --order-by LogStreamName --descending --max-items 1 --query 'logStreams[0].logStreamName' --output text | head -n 1)
    if [[ -n $stream && $stream != None ]]; then
      echo "== Newest setup failure report (any box): $group / $stream"
      aws logs get-log-events --log-group-name "$group" --log-stream-name "$stream" --limit 1 --start-from-head \
        --query 'events[0].message' --output text
    fi
    iid=$(output "$stack" InstanceId)
    if [[ -n $iid && $iid != None ]]; then
      echo "== Instance $iid: state, private IP, subnet, security groups, Owner tag"
      aws ec2 describe-instances --instance-ids "$iid" --query \
        'Reservations[0].Instances[0].[State.Name,PrivateIpAddress,SubnetId,join(`,`,SecurityGroups[].GroupId),Tags[?Key==`Owner`]|[0].Value]' --output text
      ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$iid" \
        --query 'InstanceInformationList[0].[PingStatus,LastPingDateTime]' --output text)
      echo "== Session Manager registration: ${ping:-not registered - the agent never reached Systems Manager (see the endpoint security groups below)}"
      vpc=$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].VpcId' --output text)
      echo "== Session Manager endpoints in $vpc and who their security groups allow on 443 (the box needs its subnet or security group listed)"
      for svc in ssm ssmmessages ec2messages; do
        sgs=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" "Name=service-name,Values=com.amazonaws.${AWS_REGION:-$(aws configure get region)}.$svc" \
          --query 'VpcEndpoints[0].Groups[].GroupId' --output text)
        if [[ -z $sgs || $sgs == None ]]; then
          [[ $svc == ec2messages ]] || echo "  $svc: no endpoint (traffic goes through NAT)"   # SSM Agent 3.3.40+ doesn't use it
          continue
        fi
        # shellcheck disable=SC2086
        allowed=$(aws ec2 describe-security-groups --group-ids $sgs --query \
          'SecurityGroups[].IpPermissions[?ToPort==`443` || IpProtocol==`-1`][].[IpRanges[].CidrIp, UserIdGroupPairs[].GroupId][]' --output text | tr '\t\n' '  ')
        echo "  $svc: $allowed"
      done
      echo "== Alarms"
      aws cloudwatch describe-alarms --alarm-name-prefix "claude-scan-$2-" --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
    fi
    echo "== Connecting as the user: their Owner (Identity Center attribute, or IAM user tag) must be '$2'." ;;
  delete-box)
    [[ -n ${2:-} ]] || die "usage: $0 delete-box <owner>"
    aws cloudformation delete-stack --stack-name "$(box_stack "$2")"
    aws cloudformation wait stack-delete-complete --stack-name "$(box_stack "$2")"
    echo "Deleted box for $2. Its telemetry and session recordings stay in the bucket." ;;
  grafana-setup)
    ws=$(output "$SHARED_STACK" GrafanaWorkspaceId)
    url=$(output "$SHARED_STACK" GrafanaWorkspaceUrl)
    [[ -n $ws && $ws != none ]] || die "the shared stack has no Grafana workspace (ConfigureAnalytics, CreateGrafanaWorkspace)"
    command -v jq >/dev/null || die "jq is required"
    # A short-lived admin token for the workspace's API, kept in a file rather than on command lines
    sa=$(aws grafana list-workspace-service-accounts --workspace-id "$ws" \
      --query "serviceAccounts[?name=='claude-scan-setup'].id | [0]" --output text)
    [[ -n $sa && $sa != None ]] || sa=$(aws grafana create-workspace-service-account --workspace-id "$ws" \
      --name claude-scan-setup --grafana-role ADMIN --query id --output text)
    auth=$(mktemp); trap 'rm -f "$auth"' EXIT
    aws grafana create-workspace-service-account-token --workspace-id "$ws" --service-account-id "$sa" \
      --name "setup-$(date +%s)" --seconds-to-live 900 --query serviceAccountToken.key --output text |
      sed 's/^/Authorization: Bearer /' > "$auth"
    api() { curl -fsS -H @"$auth" -H 'Content-Type: application/json' "$url/api/$1" "${@:2}"; }
    echo "== Athena plugin"
    api plugins/grafana-athena-datasource/settings >/dev/null 2>&1 ||
      api plugins/grafana-athena-datasource/install -X POST -d '{}' >/dev/null
    echo "== Data source"
    ds=$(jq -n --arg wg "$(output "$SHARED_STACK" AnalyticsWorkGroup)" --arg db "$(output "$SHARED_STACK" AnalyticsDatabase)" \
      --arg region "${AWS_REGION:-$(aws configure get region)}" \
      '{name: "Claude scan telemetry", type: "grafana-athena-datasource", access: "proxy", isDefault: true,
        jsonData: {authType: "ec2_iam_role", defaultRegion: $region, catalog: "AwsDataCatalog", database: $db, workgroup: $wg}}')
    uid=$(api datasources/name/Claude%20scan%20telemetry 2>/dev/null | jq -r .uid || true)
    if [[ -n $uid && $uid != null ]]; then api "datasources/uid/$uid" -X PUT -d "$ds" >/dev/null
    else api datasources -X POST -d "$ds" >/dev/null; fi
    echo "== Dashboards"
    for f in "$DIR"/dashboards/*.json; do
      jq '{dashboard: (. + {id: null}), overwrite: true}' "$f" | api dashboards/db -X POST -d @- | jq -r '"  " + .url'
    done
    echo "Open $url and sign in with IAM Identity Center. Assign users first (docs/dashboards.md)." ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
