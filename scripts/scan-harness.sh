#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Anthropic's defending-code-reference-harness on the Claude scan box. Run ON the box as the claude user.
# Usage:
#   scan-harness.sh setup                   # clone (or update) the harness from main
#   scan-harness.sh scan <git-url|dir>      # clone/pull the repo into ~/scan-targets, then headless static scan:
#                                           #   threat model -> vuln scan -> triage
#   scan-harness.sh sandbox                 # optional: Docker + gVisor + Bedrock key for the autonomous C/C++ pipeline
#   scan-harness.sh token                   # (re)mint the short-term Bedrock API key the sandboxed agents use
#   scan-harness.sh run <target> [args...]  # sandboxed autonomous pipeline on a harness target (e.g. drlibs)
# Override with env: HARNESS_DIR, TARGETS_DIR, RESULTS_DIR, MODEL, AWS_REGION
set -euo pipefail

HARNESS_URL=https://github.com/anthropics/defending-code-reference-harness
HARNESS_DIR="${HARNESS_DIR:-$HOME/defending-code-reference-harness}"
TARGETS_DIR="${TARGETS_DIR:-$HOME/scan-targets}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/scan-results}"
# Default to the model the box was configured with (blank = Claude Code's default)
MODEL="${MODEL:-$(jq -r '.env.ANTHROPIC_MODEL // empty' /etc/claude-code/managed-settings.json 2>/dev/null || true)}"
ENV_FILE="$HOME/.config/dcrh/bedrock.env"
SELF="$(readlink -f "$0")"

die() { echo "error: $*" >&2; exit 1; }

# claude invocation with the model pinned for the session and its subagents, when one is set
claude_cmd() {
  if [[ -n $MODEL ]]; then CLAUDE_CODE_SUBAGENT_MODEL="$MODEL" claude --model "$MODEL" "$@"; else claude "$@"; fi
}

repo_name() { basename "${1%.git}"; }

clone_or_pull() {
  if [[ -d $2/.git ]]; then git -C "$2" pull --ff-only; else git clone "$1" "$2"; fi
}

# --- Static scan (skills only read source and write reports; no sandbox needed) ---

setup() {
  clone_or_pull "$HARNESS_URL" "$HARNESS_DIR"
  cat <<EOF

Harness: $HARNESS_DIR (main @ $(git -C "$HARNESS_DIR" rev-parse --short HEAD))
Next:    $SELF scan <git-url|dir>   (headless; use tmux)
   or:   cd $HARNESS_DIR && claude      (interactive: /threat-model, /vuln-scan, /triage, /patch)
EOF
}

# Each skill's allowed-tools frontmatter pre-approves only file tools + read-only Bash,
# so headless runs can't do anything else. --add-dir lets them write reports into the target.
scan() {
  local dir out
  [[ -d $HARNESS_DIR/.claude/skills ]] || die "harness not found at $HARNESS_DIR (run setup first)"
  if [[ $1 =~ ^(https?://|git@|ssh://) ]]; then
    dir="$TARGETS_DIR/$(repo_name "$1")"
    mkdir -p "$TARGETS_DIR"
    clone_or_pull "$1" "$dir"
  else
    dir=$(readlink -f "$1")
    [[ -d $dir ]] || die "no such directory: $1"
  fi
  out="$RESULTS_DIR/$(basename "$dir")/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$out"

  skill() {
    echo "== $2"
    (cd "$HARNESS_DIR" && claude_cmd -p "$1" --add-dir "$dir") 2>&1 | tee "$out/$2.log"
  }
  skill "/threat-model bootstrap $dir" threat-model
  skill "/vuln-scan $dir" vuln-scan
  skill "/triage $dir/VULN-FINDINGS.json --repo $dir --auto" triage

  # threat-model and vuln-scan write into the target; triage writes to the harness cwd
  cp "$dir"/THREAT_MODEL.md "$dir"/VULN-FINDINGS.json "$dir"/VULN-FINDINGS.md "$out/"
  mv "$HARNESS_DIR"/TRIAGE.json "$HARNESS_DIR"/TRIAGE.md "$out/"
  echo "Results: $out"
  ls -1 "$out"
}

# --- Autonomous pipeline (executes target code; C/C++ ASAN targets only unless /customize'd) ---

imds() {
  local t
  t=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
  curl -fsS -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1"
}

region() { echo "${AWS_REGION:-$(imds placement/region)}"; }

# The docker group added by sandbox isn't active in the current login yet; sg picks it up
with_docker() {
  if docker info >/dev/null 2>&1; then "$@"; else sg docker -c "$(printf '%q ' "$SELF" "$@")"; fi
}

# Sandboxed agents can't reach IMDS or your sign-in session by design, so hand them a Bedrock-only
# bearer token signed with your current credentials (AWS_PROFILE or the instance role). It can't
# call other AWS APIs and dies when that session does (12h max).
token() {
  local r out key exp
  r=$(region)
  out=$("$HARNESS_DIR/.venv/bin/python3" -I -c '
import sys, time
from botocore.session import Session
from aws_bedrock_token_generator import provide_token
creds = Session().get_credentials()
if creds is None:
    sys.exit("no AWS credentials - sign in first (see the login banner)")
expiry = getattr(creds, "_expiry_time", None)
print(provide_token(region=sys.argv[1]))
print(int(expiry.timestamp()) if expiry else int(time.time()) + 3600)' "$r")
  key=$(sed -n 1p <<<"$out"); exp=$(sed -n 2p <<<"$out")
  install -d -m 700 "$(dirname "$ENV_FILE")"
  (umask 077; cat > "$ENV_FILE" <<EOF
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=$r
export AWS_BEARER_TOKEN_BEDROCK=$key
BEDROCK_KEY_EXPIRES=$exp
EOF
  )
  echo "Bedrock API key written to $ENV_FILE, valid until $(date -d "@$exp")"
}

load_env() {
  [[ -f $ENV_FILE ]] || die "no Bedrock key; run: $SELF token"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  (( BEDROCK_KEY_EXPIRES - $(date +%s) > 1800 )) || die "Bedrock key expires within 30 min; run: $SELF token"
}

# gVisor runtime, egress-only network + proxy (allowlist derived from the Bedrock env), target images
_sandbox() {
  load_env
  cd "$HARNESS_DIR"
  ./scripts/setup_sandbox.sh
}

sandbox() {
  [[ $(uname -m) == x86_64 ]] || die "expected x86_64"
  [[ -d $HARNESS_DIR/.git ]] || die "harness not found at $HARNESS_DIR (run setup first)"
  sudo dnf install -y docker python3.12 python3.12-pip
  sudo systemctl enable --now docker
  id -nG "$USER" | grep -qw docker || sudo usermod -aG docker "$USER"
  # AL2023's python3 is 3.9; the pipeline needs >=3.11. setup_sandbox.sh reuses this venv.
  [[ -d $HARNESS_DIR/.venv ]] || python3.12 -m venv "$HARNESS_DIR/.venv"
  "$HARNESS_DIR/.venv/bin/pip" install -q -e "$HARNESS_DIR" aws-bedrock-token-generator==1.1.0
  token
  with_docker _sandbox
  echo "Sandbox ready. Try: $SELF run drlibs   (use tmux; runs take a while)"
}

_run() {
  local target=$1; shift
  [[ $# -gt 0 ]] || set -- --runs 2 --parallel --stream --auto-focus
  [[ -n $MODEL ]] || die "the pipeline needs a model: set MODEL=<bedrock inference profile id>"
  load_env
  cd "$HARNESS_DIR"
  bin/vp-sandboxed run "$target" --model "$MODEL" "$@"
}

case "${1:-}" in
  setup) setup ;;
  scan) [[ -n ${2:-} ]] || die "usage: $0 scan <git-url|dir>"; scan "$2" ;;
  sandbox) sandbox ;;
  token) token ;;
  run) [[ -n ${2:-} ]] || die "usage: $0 run <target> [vuln-pipeline args]"; shift; with_docker _run "$@" ;;
  _sandbox) _sandbox ;;
  _run) shift; _run "$@" ;;
  *) echo "Usage: $0 setup|scan <git-url|dir>|sandbox|token|run <target> [args...]" >&2; exit 1 ;;
esac
