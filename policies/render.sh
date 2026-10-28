#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Optional (CLI): fill the SCPs/RCP with values from the shared stack, validate them with IAM Access
# Analyzer, check the size limit, and print the commands to apply them. Applies nothing.
# Console users can instead paste the JSON files and replace the placeholders by hand (see README).
# Usage: SCAN_PROFILE=<scan account profile> [MGMT_PROFILE=mgmt] [SHARED_STACK=claude-scan-shared] policies/render.sh
set -euo pipefail

SCAN_PROFILE="${SCAN_PROFILE:?set SCAN_PROFILE to the AWS profile of the scanning account}"
MGMT_PROFILE="${MGMT_PROFILE:-mgmt}"
SHARED_STACK="${SHARED_STACK:-claude-scan-shared}"
export AWS_REGION="${AWS_REGION:-us-west-2}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/out"

aws_scan() { aws --profile "$SCAN_PROFILE" "$@"; }
output() {
  aws_scan cloudformation describe-stacks --stack-name "$SHARED_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

ACCOUNT_ID=$(aws_scan sts get-caller-identity --query Account --output text)
ORG_ID=$(aws_scan organizations describe-organization --query Organization.Id --output text)
VPCE_ID=$(output BedrockVpceId)
TELEMETRY_BUCKET=$(output TelemetryBucket)
ARTIFACT_BUCKET=$(output ArtifactBucket)
ARTIFACT_PREFIX=$(output ArtifactPrefix)

# Principals that administer the account and are exempt from the guardrails: your SSO admin
# permission set, Control Tower, StackSets, the Organizations bootstrap role, and the kit's own
# platform role (Bedrock logging custom resource).
PLATFORM_PRINCIPALS=$(jq -cn --arg a "$ACCOUNT_ID" '[
  "arn:aws:iam::\($a):role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_AWSAdministratorAccess_*",
  "arn:aws:iam::\($a):role/AWSControlTowerExecution",
  "arn:aws:iam::\($a):role/aws-controltower-*",
  "arn:aws:iam::\($a):role/stacksets-exec-*",
  "arn:aws:iam::\($a):role/OrganizationAccountAccessRole",
  "arn:aws:iam::\($a):role/claude-scan-platform-*"]')

echo "account=$ACCOUNT_ID org=$ORG_ID vpce=$VPCE_ID bucket=$TELEMETRY_BUCKET kit=s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX"
mkdir -p "$OUT"

for f in "$DIR"/scp-*.json "$DIR"/rcp-*.json; do
  name=$(basename "$f" .json)
  type=SERVICE_CONTROL_POLICY; [[ $name == rcp-* ]] && type=RESOURCE_CONTROL_POLICY
  jq -c --argjson platform "$PLATFORM_PRINCIPALS" --arg boxes "arn:aws:iam::${ACCOUNT_ID}:role/claude-code-box-*" \
    --arg bucket "$TELEMETRY_BUCKET" --arg kit "$ARTIFACT_BUCKET" --arg kitprefix "$ARTIFACT_PREFIX" \
    --arg vpce "$VPCE_ID" --arg org "$ORG_ID" '
    # No Bedrock VPC endpoint in this setup: drop the statement that pins one
    (if $vpce == "none" then .Statement |= map(select(.Sid != "DenyBedrockOutsideVpce")) else . end)
    | walk(if . == "__PLATFORM_PRINCIPALS__" then $platform
           elif type == "string" then
             gsub("__BOX_ROLES__"; $boxes) | gsub("__TELEMETRY_BUCKET__"; $bucket)
             | gsub("__ARTIFACT_BUCKET__"; $kit) | gsub("__ARTIFACT_PREFIX__"; $kitprefix)
             | gsub("__VPCE_ID__"; $vpce) | gsub("__ORG_ID__"; $org)
           else . end)' "$f" > "$OUT/$name.json"
  ! grep -q '__[A-Z_]*__' "$OUT/$name.json" || { echo "unfilled placeholder in $name" >&2; exit 1; }

  size=$(wc -c < "$OUT/$name.json" | tr -d ' ')
  (( size <= 5120 )) || { echo "$name is $size chars (limit 5120)" >&2; exit 1; }
  findings=$(aws_scan accessanalyzer validate-policy --policy-type "$type" \
    --policy-document "file://$OUT/$name.json" --query 'findings[].[findingType,issueCode]' --output text)
  echo "$name: $size chars, $type, findings: ${findings:-none}"
  [[ $findings != *ERROR* ]] || exit 1
done

cat <<EOF

Rendered to $OUT. To apply (from the management account, one policy at a time; test before relying on it):
  id=\$(aws organizations create-policy --profile $MGMT_PROFILE --type SERVICE_CONTROL_POLICY \\
        --name claude-scan-guardrails --description "Claude scan account guardrails" \\
        --content file://$OUT/scp-scan-guardrails.json --query Policy.PolicySummary.Id --output text)
  aws organizations attach-policy --profile $MGMT_PROFILE --policy-id \$id --target-id $ACCOUNT_ID
Repeat for scp-scan-agent-perimeter.json (SERVICE_CONTROL_POLICY) and
rcp-scan-data-perimeter.json (--type RESOURCE_CONTROL_POLICY).
EOF
