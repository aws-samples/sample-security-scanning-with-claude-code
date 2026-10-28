# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Claude Code managed settings: Bedrock + mandatory telemetry, including content
profile=""; [[ $AUTH_MODE == InstanceRole ]] || profile=claude
refresh=""; [[ $AUTH_MODE == IdentityCenter ]] && refresh="aws sso login --profile claude --use-device-code"
install -d -m 755 /etc/claude-code
# Optional extra /model picker row for a model Claude Code doesn't list itself (e.g. Claude Mythos)
jq -n --arg region "$REGION" --arg model "$CLAUDE_MODEL" --arg owner "$OWNER" --arg kit "$KIT_VERSION" \
      --arg profile "$profile" --arg refresh "$refresh" \
      --arg xid "${EXTRA_MODEL_ID:-}" --arg xname "${EXTRA_MODEL_NAME:-}" \
      --arg xcaps "${EXTRA_MODEL_CAPABILITIES:-}" --arg xctx "${EXTRA_MODEL_CONTEXT_TOKENS:-}" '
  {env: ({
      CLAUDE_CODE_USE_BEDROCK: "1",
      AWS_REGION: $region,
      CLAUDE_CODE_ENABLE_TELEMETRY: "1",
      CLAUDE_CODE_ENHANCED_TELEMETRY_BETA: "1",
      OTEL_METRICS_EXPORTER: "otlp",
      OTEL_LOGS_EXPORTER: "otlp",
      OTEL_TRACES_EXPORTER: "otlp",
      OTEL_EXPORTER_OTLP_PROTOCOL: "http/protobuf",
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://127.0.0.1:4318",
      OTEL_METRICS_INCLUDE_VERSION: "true",
      OTEL_RESOURCE_ATTRIBUTES: ("enduser.id=" + $owner + ",claude_scan.kit_version=" + $kit),
      OTEL_LOG_USER_PROMPTS: "1",
      OTEL_LOG_ASSISTANT_RESPONSES: "1",
      OTEL_LOG_TOOL_DETAILS: "1",
      OTEL_LOG_TOOL_CONTENT: "1"
    }
    + (if $model != "" then {ANTHROPIC_MODEL: $model} else {} end)
    + (if $profile != "" then {AWS_PROFILE: $profile} else {} end)
    + (if $xid == "" then {} else
        {ANTHROPIC_CUSTOM_MODEL_OPTION: $xid}
        + (if $xname != "" then {ANTHROPIC_CUSTOM_MODEL_OPTION_NAME: $xname} else {} end)
        + (if $xcaps != "" then {ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES: $xcaps} else {} end)
        + (if $xctx != "" then {CLAUDE_CODE_MAX_CONTEXT_TOKENS: $xctx} else {} end)
      end))}
  + (if $refresh != "" then {awsAuthRefresh: $refresh} else {} end)' > /etc/claude-code/managed-settings.json
