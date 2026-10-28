#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Security Scanning with Claude Code on AWS - box health check. Run it on the box when something doesn't work (no sudo needed):
#   claude-scan-doctor
# Checks setup, sign-in, Bedrock, telemetry delivery, Session Manager and internet access, and says what to fix.
set -uo pipefail
# shellcheck disable=SC1091
source /etc/claude-scan/box.env
for f in /etc/claude-scan/settings.env /etc/profile.d/claude-scan.sh /etc/profile.d/claude-scan-ca.sh; do
  # shellcheck disable=SC1090
  [[ -r $f ]] && source "$f"
done

problems=0
pass() { printf '  PASS  %-16s %s\n' "$1" "$2"; }
fail() { printf '  FAIL  %-16s %s\n' "$1" "$2"; problems=$((problems + 1)); }
note() { printf '  ----  %-16s %s\n' "$1" "$2"; }

echo "Claude scan box $OWNER - kit $(cat /etc/claude-scan/kit-version 2>/dev/null || echo unknown), sign-in ${AUTH_MODE:-unknown}"

# Setup modules: the latest result of each
failed=$(awk '{ last[$2] = $3 } END { for (m in last) if (last[m] == "FAILED") print m }' /var/log/claude-scan-modules.log 2>/dev/null | sort | paste -sd, -)
if [[ -n $failed ]]; then fail setup "failed: $failed - rerun with: sudo claude-scan-bootstrap --only <module>"
else pass setup "all setup modules finished"; fi

# Sign-in
case ${AUTH_MODE:-} in
  IamUser)        signin="aws login --remote --profile claude-login" ;;
  IdentityCenter) signin="aws sso login --profile claude --use-device-code" ;;
  *)              signin="" ;;
esac
if who=$(aws sts get-caller-identity --query Arn --output text 2>&1); then pass sign-in "$who"
elif [[ -n $signin ]]; then fail sign-in "not signed in, or the session expired - run: $signin"
else fail sign-in "the box role has no credentials: ${who:0:150}"; fi

# Bedrock: one-token call to the default model (proves identity, permissions and model access)
if [[ -z ${CLAUDE_MODEL:-} ]]; then
  note bedrock "no default model set (shared stack ClaudeModel), so no test call"
elif out=$(aws bedrock-runtime converse --model-id "$CLAUDE_MODEL" --inference-config maxTokens=1 \
             --messages '[{"role":"user","content":[{"text":"ok"}]}]' --query stopReason --output text 2>&1); then
  pass bedrock "$CLAUDE_MODEL answered"
else
  fail bedrock "$CLAUDE_MODEL: ${out:0:220}"
fi

# Telemetry: collector up, and its S3 queue emptying (a healthy queue stays small)
if curl -fs -m 3 http://127.0.0.1:13133/ > /dev/null; then
  queued=$(curl -s -m 3 http://127.0.0.1:8888/metrics | awk '/^otelcol_exporter_queue_size\{.*awss3/ { print $NF }' | sort -n | tail -n 1)
  if (( ${queued:-0} > 100 )); then fail telemetry "collector running, but $queued requests are queued - telemetry isn't reaching the bucket (bucket, KMS key or S3 endpoint policy)"
  else pass telemetry "collector running, S3 queue ${queued:-0}"; fi
else
  fail telemetry "collector not running - run: sudo systemctl restart otelcol-contrib (the admin is alerted while it's down)"
fi

# Session Manager agent
if systemctl is-active --quiet amazon-ssm-agent; then pass session-manager "SSM agent running"
else fail session-manager "SSM agent not running - run: sudo systemctl restart amazon-ssm-agent"; fi

# Internet access for Git, packages and Claude Code updates
for host in github.com registry.npmjs.org pypi.org downloads.claude.ai; do
  rc=0; curl -sS -o /dev/null --connect-timeout 5 --max-time 15 "https://$host/" 2> /dev/null || rc=$?
  case $rc in
    0)        pass internet "$host" ;;
    6)        fail internet "$host - DNS lookup failed" ;;
    35|60|77) fail internet "$host - TLS certificate not trusted (TLS inspection? the admin can set the shared stack's CorporateCaBundleKey)" ;;
    *)        fail internet "$host - no connection (curl exit $rc)" ;;
  esac
done
[[ -z ${NODE_EXTRA_CA_CERTS:-} ]] || note corporate-ca "trusting $NODE_EXTRA_CA_CERTS"

echo
if (( problems == 0 )); then echo "No problems found."; else echo "$problems problem(s) found."; fi
(( problems == 0 ))
