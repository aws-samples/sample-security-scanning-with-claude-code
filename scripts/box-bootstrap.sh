#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Security Scanning with Claude Code on AWS - box bootstrap runner. EC2 user data (box.yaml) runs it once as root at first boot.
# It reads /etc/claude-scan/box.env, downloads the setup modules (scripts/modules/<name>.sh) from the
# kit bucket, and runs them in order, skipping the optional ones the box stack didn't select.
#
# Rerun modules later as root, e.g. to add a toolchain the box was built without:
#   sudo claude-scan-bootstrap --only toolchain-rust
set -euo pipefail
# shellcheck disable=SC1091
source /etc/claude-scan/box.env

# Run order. Optional modules run only when selected() says so.
MODULES=(
  corporate-ca preflight user base-packages telemetry
  toolchain-java toolchain-node toolchain-python toolchain-go toolchain-rust toolchain-cpp toolchain-dotnet
  extra-packages sandbox claude-code aws-profile managed-settings harness doctor banner verify
)

# Box stacks created before these settings existed: same result as before
if [[ -z ${TOOLCHAINS:-} ]]; then
  if [[ ${INSTALL_TOOLCHAINS:-true} == true ]]; then TOOLCHAINS=java,node,python,go,rust,cpp,dotnet; else TOOLCHAINS=none; fi
fi
INSTALL_HARNESS=${INSTALL_HARNESS:-true}

LIB_DIR=/usr/local/lib/claude-scan
MODULE_DIR=$LIB_DIR/modules
FAILURE_FILE=/var/log/claude-scan-bootstrap.failure   # user data reports its content if the bootstrap fails
STATUS_LOG=/var/log/claude-scan-modules.log
U=claude
# shellcheck disable=SC2034  # used by the modules
H=/home/$U

# Run a command as the claude user (pipefail, so 'curl ... | bash' fails when the download does). A failure
# is returned rather than raised here, so the module's ERR trap reports the module's own line and command.
as_user() { local rc=0; sudo -iu "$U" bash -o pipefail -lc "$1" || rc=$?; return "$rc"; }

selected() {   # $1 = module
  case $1 in
    corporate-ca)   [[ -n ${CORPORATE_CA_KEY:-} && ${CORPORATE_CA_KEY:-} != none ]] ;;
    toolchain-*)    [[ ,$TOOLCHAINS, == *,${1#toolchain-},* ]] ;;
    extra-packages) [[ -n ${EXTRA_PACKAGES//[[:space:]]/} ]] ;;
    sandbox)        [[ $ENABLE_SANDBOX == true ]] ;;
    harness)        [[ $INSTALL_HARNESS == true ]] ;;
    *)              true ;;
  esac
}

fail() {
  echo "$1 [kit $KIT_VERSION]" > "$FAILURE_FILE"
  echo "=== claude-scan bootstrap FAILED: $1" >&2
  exit 1
}

# A module's ERR trap: record the first failure as module, line and command
record_failure() {   # $1 = exit code, $2 = line, $3 = command
  local cmd=$3
  [ -e "$FAILURE_FILE" ] && return 0
  # A failed as_user call shows up as its 'return'; the module's own line says more
  [[ $cmd == return* ]] && cmd=$(sed -n "$2{s/^[[:space:]]*//;p}" "$MODULE_DIR/$m.sh")
  echo "module $m: exit $1 at $m.sh line $2: $cmd" > "$FAILURE_FILE"
}

status() {   # $1 = module, $2 = result, $3 = seconds
  printf '%s  %-18s %-8s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$STATUS_LOG"
}

download_modules() {
  local m src="s3://$ARTIFACT_BUCKET/${ARTIFACT_PREFIX}scripts"
  install -d -m 755 "$MODULE_DIR"
  aws s3 cp --quiet --region "$REGION" "$src/VERSION" "$LIB_DIR/VERSION" ||
    fail "could not download $src/VERSION - upload the whole kit folder, including scripts/"
  for m in "${MODULES[@]}"; do
    aws s3 cp --quiet --region "$REGION" "$src/modules/$m.sh" "$MODULE_DIR/$m.sh" ||
      fail "could not download $src/modules/$m.sh - upload the whole kit folder, including scripts/modules/"
  done
}

# Sign-in and model settings are shared by all boxes: the shared stack keeps them in an SSM parameter.
# They're read on every run, so after the admin changes one, a box picks it up with
#   sudo claude-scan-bootstrap --only aws-profile managed-settings banner
load_settings() {
  local json
  [[ -n ${BOX_SETTINGS_PARAMETER:-} ]] || return 0   # older box stacks keep these values in box.env
  json=$(aws ssm get-parameter --region "$REGION" --name "$BOX_SETTINGS_PARAMETER" --query Parameter.Value --output text 2>&1) ||
    fail "could not read the shared stack's box settings ($BOX_SETTINGS_PARAMETER): ${json:0:300}"
  python3 -I -c '
import json, shlex, sys
for k, v in json.load(sys.stdin).items():
    if k.isupper() and k.replace("_", "").isalnum():
        print(f"{k}={shlex.quote(str(v))}")' <<<"$json" > /etc/claude-scan/settings.env ||
    fail "the shared stack's box settings ($BOX_SETTINGS_PARAMETER) are not valid JSON"
  # shellcheck disable=SC1091
  source /etc/claude-scan/settings.env
  echo "=== claude-scan settings from $BOX_SETTINGS_PARAMETER: sign-in $AUTH_MODE, model ${CLAUDE_MODEL:-Claude Code default}"
}

# The release zip stamps scripts/VERSION and box.yaml with the kit's commit date and hash (git archive
# export-subst, see .gitattributes); files copied from a git checkout keep the placeholder ("dev")
kit_version() {   # $1 = stamped value
  if [[ -z $1 || $1 == *Format:* ]]; then echo dev; else echo "$1"; fi
}

# Each module runs in its own subshell with -e, so the first failing command stops it and the ERR trap
# records the module, line and command. 'set +e' around the subshell lets the runner report the result
# (calling it from an 'if' would turn -e off inside the module).
run_module() {   # $1 = module
  local m=$1 start rc
  start=$(date +%s)
  echo "=== claude-scan module $m: start"
  set +e
  (
    set -Eeuxo pipefail
    trap 'record_failure $? $LINENO "$BASH_COMMAND"' ERR
    # Modules running as root (npm, pip) need the corporate CA settings too; as_user's login shell reads them itself
    # shellcheck disable=SC1091
    [[ ! -r /etc/profile.d/claude-scan-ca.sh ]] || source /etc/profile.d/claude-scan-ca.sh
    # shellcheck disable=SC1090
    source "$MODULE_DIR/$m.sh"
  )
  rc=$?
  set -e
  if (( rc != 0 )); then
    [ -e "$FAILURE_FILE" ] || echo "module $m: exit $rc (see the output above)" > "$FAILURE_FILE"
    sed -i "1s/\$/ [kit $KIT_VERSION]/" "$FAILURE_FILE"
    status "$m" FAILED "$(( $(date +%s) - start ))s"
    echo "=== claude-scan module $m: FAILED (exit $rc)"
    exit "$rc"
  fi
  status "$m" ok "$(( $(date +%s) - start ))s"
  echo "=== claude-scan module $m: ok ($(( $(date +%s) - start ))s)"
}

rm -f "$FAILURE_FILE"
KIT_VERSION=$(kit_version "$(head -n1 "$LIB_DIR/VERSION" 2>/dev/null || true)")
case ${1:-} in
  "")
    download_modules
    load_settings
    KIT_VERSION=$(kit_version "$(head -n1 "$LIB_DIR/VERSION")")
    echo "$KIT_VERSION" > /etc/claude-scan/kit-version
    template_version=$(kit_version "${KIT_TEMPLATE_VERSION:-}")
    echo "=== claude-scan kit $KIT_VERSION (box.yaml: $template_version)"
    if [[ $KIT_VERSION != dev && $template_version != dev && $KIT_VERSION != "$template_version" ]]; then
      echo "=== WARNING: this box stack's box.yaml is from kit $template_version but the scripts in the kit bucket are from kit $KIT_VERSION - upload and deploy the same kit version"
    fi
    for m in "${MODULES[@]}"; do
      if selected "$m"; then
        run_module "$m"
      else
        status "$m" skipped -
        echo "=== claude-scan module $m: skipped (not selected for this box)"
      fi
    done
    echo "claude-scan bootstrap complete"
    ;;
  --only)
    shift
    (( $# > 0 )) || { echo "usage: claude-scan-bootstrap [--only <module>...]  modules: ${MODULES[*]}" >&2; exit 2; }
    for m in "$@"; do
      [[ " ${MODULES[*]} " == *" $m "* ]] || { echo "unknown module '$m'; modules: ${MODULES[*]}" >&2; exit 2; }
    done
    load_settings
    for m in "$@"; do run_module "$m"; done
    ;;
  *)
    echo "usage: claude-scan-bootstrap [--only <module>...]" >&2
    exit 2
    ;;
esac
