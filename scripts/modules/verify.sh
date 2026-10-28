# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Claude Code runs, the telemetry collector is healthy, and Session Manager can reach the box
as_user 'claude --version'
for _ in $(seq 1 30); do curl -fs http://127.0.0.1:13133/ >/dev/null && break; sleep 2; done
curl -fs http://127.0.0.1:13133/ >/dev/null

# Session Manager is the only way in. The SSM agent opens its control channel once it's registered and
# allowed to connect; without it the stack would complete but nobody could connect (TargetNotConnected).
agent_log=/var/log/amazon/ssm/amazon-ssm-agent.log
# Only a connection since the agent last started counts (it logs its version at each start, e.g. after
# updating itself). Patterns match the agent's own timestamped lines: the log also holds command output.
connected() {
  [[ -r $agent_log ]] && awk '
    /^[0-9-]+ [0-9:.]+ INFO \[amazon-ssm-agent\] amazon-ssm-agent - v[0-9]/ { ok = 0 }
    /^[0-9-]+ [0-9:.]+ INFO \[ssm-agent-worker\] .*(Set up control channel successfully|SSM Connection channel status is set to ssmmessages)/ { ok = 1 }
    END { exit !ok }' "$agent_log"
}
for _ in $(seq 1 "${SSM_CONNECT_CHECKS:-36}"); do connected && break; sleep 5; done
if ! connected; then
  err=$(grep -h -E "^[0-9-]+ [0-9:.]+ ERROR" "$agent_log" 2>/dev/null | tail -n 1 | cut -c1-300 || true)
  echo "module verify: the SSM agent didn't connect to Session Manager within 3 minutes, so nobody could connect to this box. Check that SCPs and the ssm/ssmmessages VPC endpoint policies allow the box role. Last agent error: ${err:-none}" > "$FAILURE_FILE"
  exit 1
fi
