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
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
