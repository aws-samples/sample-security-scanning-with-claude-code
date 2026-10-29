# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Preflight (always runs first): before installing anything, check that the box can reach and use
# everything setup needs. Each check prints PASS or FAIL with what to fix. Any FAIL fails the bootstrap
# with one summary line, which user data reports to CloudWatch Logs and the instance console.
set +x   # the PASS/FAIL lines are the useful output here

# Failed checks are grouped by what to fix, so the summary names each fix once
declare -A fix_checks=()
fixes=()
nfailed=0
pass()   { printf '  PASS  %-40s %s\n' "$1" "$2"; }
failed() {   # $1 = check, $2 = what's wrong and what to fix
  printf '  FAIL  %-40s %s\n' "$1" "$2"
  nfailed=$((nfailed + 1))
  if [[ -z ${fix_checks[$2]+set} ]]; then fixes+=("$2"); fix_checks[$2]=$1; else fix_checks[$2]+=", $1"; fi
}

# Fail fast instead of the CLI's long default retries against an unreachable endpoint
export AWS_MAX_ATTEMPTS=2
awsq() { aws --region "$REGION" --cli-connect-timeout 5 --cli-read-timeout 20 "$@"; }

imds() {
  local token
  token=$(curl -fs -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token) &&
    curl -fs -m 2 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}
instance_id=$(imds instance-id || echo unknown)
subnet_cidr=$(imds "network/interfaces/macs/$(imds mac)/subnet-ipv4-cidr-block" || echo "the box subnet")

# HTTPS reachability. Any HTTP answer counts (the service is there); curl's own errors say what's in the way.
reach() {   # $1 = host, $2 = what it's for, $3 = what to fix when there's no connection
  local rc=0 err
  err=$(curl -sS -o /dev/null --connect-timeout 5 --max-time 20 "https://$1/" 2>&1) || rc=$?
  case $rc in
    0)        pass "$1" "$2" ;;
    6)        failed "$1" "DNS lookup failed - check Route 53 Resolver DNS Firewall rules and the VPC's DHCP options" ;;
    7|28)     failed "$1" "no connection - $3" ;;
    35|60|77) failed "$1" "TLS certificate not trusted, likely TLS inspection - exempt the host from inspection, or upload the inspecting CA with the kit and set the shared stack's CorporateCaBundleKey" ;;
    *)        failed "$1" "curl exit $rc: ${err:0:200}" ;;
  esac
}

echo "Preflight checks (instance $instance_id, subnet $subnet_cidr)"

# Amazon Linux package repositories (an AWS-owned S3 bucket, reached through the VPC's S3 path)
if out=$(dnf -q makecache --refresh 2>&1); then
  pass amazon-linux-repos "package metadata downloaded"
elif [[ $out == *403* ]]; then
  failed amazon-linux-repos "HTTP 403 from the Amazon Linux repositories - the VPC's S3 gateway endpoint policy must allow s3:GetObject on arn:aws:s3:::al2023-repos-$REGION-de612dc2/*"
else
  failed amazon-linux-repos "$(grep -m1 -i -E 'error|fail|curl' <<<"$out" | cut -c1-250)"
fi

# Telemetry bucket: write a small marker where the collector will write
key="claude-code/$OWNER/preflight/$instance_id.txt"
if out=$(echo "preflight $(date -u +%Y-%m-%dT%H:%M:%SZ)" | awsq s3 cp - "s3://$TELEMETRY_BUCKET/$key" 2>&1); then
  pass telemetry-bucket "wrote s3://$TELEMETRY_BUCKET/$key"
else
  case $out in
    *kms*|*KMS*)          failed telemetry-bucket "KMS denied writing to $TELEMETRY_BUCKET - the bucket's KMS key policy must let this box role use the key through S3, and with your own bucket the shared stack's ExistingKmsKeyArn must be that bucket's key: ${out:0:200}" ;;
    *AccessDenied*)       failed telemetry-bucket "PutObject denied on s3://$TELEMETRY_BUCKET/$key - check the VPC's S3 gateway endpoint policy (if any) and the bucket policy" ;;
    *connect*|*Connect*)  failed telemetry-bucket "no connection to S3 - the box subnet needs an S3 gateway endpoint or a NAT route" ;;
    *)                    failed telemetry-bucket "${out:0:250}" ;;
  esac
fi

# Session Manager checks the bucket's encryption before it saves a session recording
if [[ ${SESSION_MANAGER_CONFIGURED:-No} == Yes ]]; then
  if out=$(awsq s3api get-bucket-encryption --bucket "$TELEMETRY_BUCKET" 2>&1); then
    pass session-recordings "bucket encryption readable"
  else
    failed session-recordings "GetEncryptionConfiguration denied on $TELEMETRY_BUCKET - the VPC's S3 gateway endpoint policy must allow s3:GetEncryptionConfiguration on the bucket: ${out:0:150}"
  fi
fi

# CloudWatch Logs: heartbeat metric, failure reports and session recordings
if out=$(awsq logs describe-log-streams --log-group-name "$HEARTBEAT_LOG_GROUP" --max-items 1 2>&1); then
  pass cloudwatch-logs "$HEARTBEAT_LOG_GROUP"
else
  case $out in
    *connect*|*Connect*) failed cloudwatch-logs "no connection to logs.$REGION.amazonaws.com - needs NAT, or a logs interface endpoint whose security group allows HTTPS from $subnet_cidr" ;;
    *)                   failed cloudwatch-logs "${out:0:250}" ;;
  esac
fi

# Session Manager (the only way to connect), Bedrock, and CloudFormation (the box's setup signal)
endpoint_fix="if the VPC has interface endpoints for these services, their security group must allow HTTPS (443) from $subnet_cidr; otherwise the subnet needs NAT"
reach "ssm.$REGION.amazonaws.com" "Session Manager" "$endpoint_fix"
reach "ssmmessages.$REGION.amazonaws.com" "Session Manager" "$endpoint_fix"
reach "bedrock-runtime.$REGION.amazonaws.com" "Bedrock" "$endpoint_fix"
reach "bedrock.$REGION.amazonaws.com" "Bedrock model lookups" "$endpoint_fix"
reach "cloudformation.$REGION.amazonaws.com" "setup signal" "$endpoint_fix"

# Internet downloads, only for what this box installs
internet_fix="allow outbound HTTPS to this host (NAT and firewall)"
hosts=(github.com release-assets.githubusercontent.com claude.ai downloads.claude.ai)
selected toolchain-node && hosts+=(registry.npmjs.org)
selected toolchain-python && hosts+=(pypi.org files.pythonhosted.org)
for h in "${hosts[@]}"; do reach "$h" "downloads" "$internet_fix"; done

if (( nfailed > 0 )); then
  summary=""
  for f in "${fixes[@]}"; do summary+="${fix_checks[$f]}: $f; "; done
  echo "preflight: $nfailed check(s) failed - ${summary%; }" > "$FAILURE_FILE"
  exit 1
fi
echo "All preflight checks passed"
