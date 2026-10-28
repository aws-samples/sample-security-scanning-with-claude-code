# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# AWS CLI profile for the box stack's sign-in mode, used by Claude Code and scan-harness.sh
install -d -o "$U" -g "$U" -m 700 "$H/.aws"
case $AUTH_MODE in
  IdentityCenter)
    cat > "$H/.aws/config" <<EOF
[sso-session claude]
sso_start_url = $SSO_START_URL
sso_region = $SSO_REGION
sso_registration_scopes = sso:account:access

[profile claude]
sso_session = claude
sso_account_id = $SSO_ACCOUNT_ID
sso_role_name = $SSO_ROLE_NAME
region = $REGION
EOF
    ;;
  IamUser)
    cat > "$H/.aws/config" <<EOF
# 'aws login --remote --profile claude-login' stores your console sign-in session here
[profile claude-login]
region = $REGION

# Claude Code and scan-harness.sh use this profile, which reads the login session
[profile claude]
credential_process = aws configure export-credentials --profile claude-login --format process
region = $REGION
EOF
    ;;
  *)
    printf '[default]\nregion = %s\n' "$REGION" > "$H/.aws/config"
    ;;
esac
chown "$U:$U" "$H/.aws/config"

{
  echo "export AWS_REGION=$REGION"
  [[ $AUTH_MODE == InstanceRole ]] || echo "export AWS_PROFILE=claude"
} > /etc/profile.d/claude-scan.sh
