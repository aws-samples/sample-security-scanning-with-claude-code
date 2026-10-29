# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Login banner (Session Manager shells don't show /etc/motd)
case $AUTH_MODE in
  IamUser)        signin="aws login --remote --profile claude-login   (open the link on your laptop, paste the code back)" ;;
  IdentityCenter) signin="aws sso login --profile claude --use-device-code" ;;
  *)              signin="(none needed - this box's role calls Bedrock)" ;;
esac
# The scan line appears only where the harness is installed (also after a later '--only harness')
cat > /etc/profile.d/zz-claude-scan-welcome.sh <<EOF
[[ \$- == *i* && \$(id -un) == $U && -z \${CLAUDE_SCAN_WELCOMED:-} ]] || return 0
export CLAUDE_SCAN_WELCOMED=1
cat <<'BANNER'

  Claude scan box - owner: $OWNER   (kit $KIT_VERSION)

  NOTICE: your activity here is recorded for audit - your terminal sessions and Claude Code activity
  (prompts, responses, commands it runs, and file contents it reads).

  1. Sign in:   $signin
  2. Start:     tmux             (keeps long jobs alive if your connection drops; mouse wheel scrolls back)
  3. Use:       claude           (Claude Code)
BANNER
if command -v scan-harness.sh >/dev/null; then
  echo "                scan-harness.sh scan <git-url|dir>     (threat model -> vuln scan -> triage)"
fi
echo "  Problems?     claude-scan-doctor"
echo
EOF
