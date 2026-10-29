#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Anthropic's defending-code-reference-harness on the Claude scan box. Run ON the box as the claude user.
# Usage:
#   scan-harness.sh setup                   # clone the harness and check out the pinned commit (HARNESS_REF)
#   scan-harness.sh scan <git-url|dir>      # headless static scan of a fresh copy of the repo, as the
#                                           #   claude-scanner user: threat model -> vuln scan -> triage
#   scan-harness.sh sandbox                 # optional: Docker + gVisor + Bedrock key for the autonomous C/C++ pipeline
#   scan-harness.sh token                   # (re)mint the short-term Bedrock API key the sandboxed agents use
#   scan-harness.sh run <target> [args...]  # sandboxed autonomous pipeline on a harness target (e.g. drlibs)
# Override with env: HARNESS_DIR, HARNESS_REF, RESULTS_DIR, MODEL, AWS_REGION
set -euo pipefail

HARNESS_URL=https://github.com/anthropics/defending-code-reference-harness
# The harness commit this kit was tested with; HARNESS_REF=main scan-harness.sh setup moves to the latest
HARNESS_REF="${HARNESS_REF:-d3bea6b5793b5f3d59a75ebe69a58efa88383145}"
HARNESS_DIR="${HARNESS_DIR:-$HOME/defending-code-reference-harness}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/scan-results}"
# Default to the model the box was configured with (blank = Claude Code's default)
MODEL="${MODEL:-$(jq -r '.env.ANTHROPIC_MODEL // empty' /etc/claude-code/managed-settings.json 2>/dev/null || true)}"
ENV_FILE="$HOME/.config/dcrh/bedrock.env"
SELF="$(readlink -f "$0")"
# Headless scans run as this user (set up by the box's harness module)
SCANNER=claude-scanner
SCANS_DIR=/var/lib/claude-scan/scans
TOKEN_PY=/usr/local/lib/claude-scan/bedrock-token/bin/python3

die() { echo "error: $*" >&2; exit 1; }

setup() {
  [[ -d $HARNESS_DIR/.git ]] || git clone -q "$HARNESS_URL" "$HARNESS_DIR"
  git -C "$HARNESS_DIR" fetch -q origin
  git -C "$HARNESS_DIR" checkout -q --detach "$HARNESS_REF"
  cat <<EOF

Harness: $HARNESS_DIR (@ $(git -C "$HARNESS_DIR" rev-parse --short HEAD))
Next:    $SELF scan <git-url|dir>   (headless; use tmux)
   or:   cd $HARNESS_DIR && claude      (interactive: /threat-model, /vuln-scan, /triage, /patch)
EOF
}

# --- Headless static scan ---
# The harness skills' allowed-tools only pre-approve tools (including git, find and gh api); they don't stop
# anything else, and the repository under scan can steer the agent. So each scan runs on a fresh copy of the
# repository and the harness, as the claude-scanner user: no sudo, no access to your home directory or your
# AWS sign-in, only a short-term Bedrock API key, and firewall rules that allow only the VPC's endpoints (no
# internet, no instance metadata). Telemetry is recorded as for your own sessions.

# host/org/repo for a Git URL, local/<path> for a directory: results of different repositories never mix
target_name() {
  local t=$1 url_re='^(https?|ssh)://([^/@]*@)?([^/:]+)(:[0-9]+)?/(.+)$' scp_re='^[^@/]+@([^:/]+):(.+)$'
  if [[ $t =~ $url_re ]]; then t="${BASH_REMATCH[3]}/${BASH_REMATCH[5]}"
  elif [[ $t =~ $scp_re ]]; then t="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else t="local$t"; fi
  t=${t%/}; t=${t%.git}
  [[ /$t/ != */../* ]] || die "unexpected '..' in $1"
  printf '%s' "$t" | tr -c 'A-Za-z0-9._/-' '_'
}

# A Bedrock API key minted from your current sign-in: it can only call Bedrock and expires with that session
mint_key() {
  [[ -x $TOKEN_PY ]] || die "Bedrock key tool missing; run: sudo claude-scan-bootstrap --only harness"
  "$TOKEN_PY" -I -c '
import sys
from botocore.session import Session
from aws_bedrock_token_generator import provide_token
if Session().get_credentials() is None:
    sys.exit("no AWS credentials - sign in first (see the login banner)")
print(provide_token(region=sys.argv[1]))' "$(region)"
}

# claude-scanner has no internet path: model calls must reach Bedrock through the VPC's endpoint
bedrock_in_vpc() {
  python3 -I -c '
import ipaddress, socket, sys
ip = ipaddress.ip_address(socket.gethostbyname(sys.argv[1]))
sys.exit(0 if any(ip in ipaddress.ip_network(c) for c in open(sys.argv[2]).read().split()) else 1)' \
    "bedrock-runtime.$(region).amazonaws.com" /etc/claude-scan/scanner-vpc-cidrs 2>/dev/null
}

# The scan's staging and run directories: global, so the EXIT trap still sees them after scan returns
stage="" run=""

scan() {
  local target=$1 name started out commit harness_commit
  [[ -d $HARNESS_DIR/.git ]] || die "harness not found at $HARNESS_DIR (run setup first)"
  id "$SCANNER" >/dev/null 2>&1 || die "the $SCANNER user is missing; run: sudo claude-scan-bootstrap --only harness"
  sudo nft list table inet claude_scanner >/dev/null 2>&1 ||
    die "the $SCANNER firewall rules aren't loaded; run: sudo systemctl restart claude-scan-scanner-firewall"
  bedrock_in_vpc || die "bedrock-runtime.$(region).amazonaws.com doesn't resolve to a VPC endpoint; headless scans need the bedrock-runtime and bedrock interface endpoints (shared stack InterfaceEndpoints)"

  started=$(date -u +%Y%m%dT%H%M%SZ)
  if [[ $target =~ ^(https?://|git@|ssh://) ]]; then
    name=$(target_name "$target")
  else
    target=$(readlink -f "$target")
    [[ -d $target ]] || die "no such directory: $1"
    name=$(target_name "$target")
  fi
  out="$RESULTS_DIR/$name/$started"
  mkdir -p "$out"
  info() { jq -n --arg status "$1" --arg step "${2:-}" --arg message "${3:-}" --arg target "$target" \
    --arg commit "${commit:-}" --arg harness "${harness_commit:-}" --arg model "$MODEL" --arg started "$started" \
    --arg kit "$(cat /etc/claude-scan/kit-version 2>/dev/null || echo unknown)" \
    '{status: $status, failed_step: $step, message: $message, target: $target, commit: $commit,
      harness_commit: $harness, model: $model, kit_version: $kit, started_at: $started,
      finished_at: (now | todate)}' > "$out/SCAN-INFO.json"; }
  fail() { info failed "$1" "$2"; die "$1: $2 (details: $out)"; }

  # Fresh copies of the repository and the pinned harness, so nothing from an earlier run is reused
  stage=$(mktemp -d)
  run="$SCANS_DIR/$started-$$"
  trap '[[ -z $stage ]] || rm -rf "$stage"; [[ -z $run ]] || sudo rm -rf "$run"' EXIT
  if [[ -d $target ]]; then cp -a "$target" "$stage/src"; else git clone -q -- "$target" "$stage/src" || fail clone "git clone failed"; fi
  rm -f "$stage/src/THREAT_MODEL.md" "$stage/src/VULN-FINDINGS.json" "$stage/src/VULN-FINDINGS.md"
  commit=$(git -C "$stage/src" rev-parse HEAD 2>/dev/null || echo none)
  harness_commit=$(git -C "$HARNESS_DIR" rev-parse HEAD)
  mkdir "$stage/harness"
  git -C "$HARNESS_DIR" archive HEAD | tar -x -C "$stage/harness"

  sudo install -d -o "$SCANNER" -g "$SCANNER" -m 700 "$run"
  sudo cp -a "$stage/src" "$stage/harness" "$run/"
  sudo chown -R "$SCANNER:$SCANNER" "$run"
  mint_key | sudo -u "$SCANNER" sh -c 'umask 077; sed "s/^/export AWS_BEARER_TOKEN_BEDROCK=/" > "$1"' _ "$run/bedrock.env" ||
    fail key "could not mint a Bedrock API key (sign in first; see the login banner)"

  # $1 = step name, $2 = prompt. A clean environment: none of your variables, credentials or files.
  step() {
    echo "== $1"
    sudo -u "$SCANNER" -H env -i HOME="/home/$SCANNER" PATH="/home/$SCANNER/.local/bin:/usr/bin:/bin" \
      LANG=C.UTF-8 ${MODEL:+CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"} \
      bash -c 'source "$1/bedrock.env"; cd "$1/harness"; shift; exec claude "$@" </dev/null' _ "$run" \
      -p "$2" --add-dir "$run/src" --disallowedTools WebFetch WebSearch ${MODEL:+--model "$MODEL"} 2>&1 |
      tee "$out/$1.log" || fail "$1" "claude exited with an error (see $1.log)"
  }
  # Reports must exist and be complete: an empty or partial run fails instead of looking like a result
  check() {   # $1 = step, $2 = file in $run, $3 = jq test (optional)
    sudo test -s "$run/$2" || fail "$1" "$(basename "$2") wasn't written"
    [[ -z ${3:-} ]] || sudo cat "$run/$2" | jq -e "$3" >/dev/null 2>&1 || fail "$1" "$(basename "$2") isn't complete"
  }

  step threat-model "/threat-model bootstrap $run/src"
  check threat-model src/THREAT_MODEL.md
  step vuln-scan "/vuln-scan $run/src"
  check vuln-scan src/VULN-FINDINGS.json '.findings | type == "array"'
  check vuln-scan src/VULN-FINDINGS.md
  step triage "/triage $run/src/VULN-FINDINGS.json --repo $run/src --auto"
  check triage harness/TRIAGE.json '.triage_completed == true'
  check triage harness/TRIAGE.md

  for f in src/THREAT_MODEL.md src/VULN-FINDINGS.json src/VULN-FINDINGS.md harness/TRIAGE.json harness/TRIAGE.md; do
    # shellcheck disable=SC2024  # the copy belongs to you; sudo only reads claude-scanner's file
    sudo cat "$run/$f" > "$out/$(basename "$f")"
  done
  info ok
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
