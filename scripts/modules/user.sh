# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# The 'claude' user. Full sudo: telemetry is protected by detection, not by permissions.
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-claude-scan
chmod 440 /etc/sudoers.d/90-claude-scan

# tmux keeps its own scrollback: let the mouse wheel scroll it, and keep enough for long Claude sessions
cat > "$H/.tmux.conf" <<'TMUX'
set -g mouse on
set -g history-limit 50000
TMUX
chown "$U:$U" "$H/.tmux.conf"
