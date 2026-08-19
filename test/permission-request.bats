#!/usr/bin/env bats
# Tests for the PermissionRequest hook contract: decision schema, ask-by-
# silence, reentrancy guard, CRLF tolerance, and hook registration.

load test_helper

@test "pr: simple deny decision schema is exact" {
  run_hook "rm -rf /" '["Bash(rm *)"]'
  [[ "$status" -eq 0 ]]
  run bash -c 'printf "%s" "$1" | jq -e '\''.hookSpecificOutput.hookEventName == "PermissionRequest" and .hookSpecificOutput.decision.behavior == "deny" and (.hookSpecificOutput.decision.message | type == "string") and (.systemMessage | type == "string")'\''' _ "$output"
  [[ "$status" -eq 0 ]]
}

@test "pr: compound deny decision schema is exact" {
  run_hook "ls && rm -rf /" '["Bash(rm -rf *)"]'
  [[ "$status" -eq 0 ]]
  run bash -c 'printf "%s" "$1" | jq -e '\''.hookSpecificOutput.hookEventName == "PermissionRequest" and .hookSpecificOutput.decision.behavior == "deny"'\''' _ "$output"
  [[ "$status" -eq 0 ]]
}

@test "pr: Stage 2 ask emits nothing (native prompt escalates)" {
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"ask\",\"reason\":\"uncertain\"}","cost_usd":0.001}'
  run_hook_smart "unknown_cmd" '[]' "$mock_resp"
  assert_fallthrough
}

@test "pr: Stage 2 failure emits nothing" {
  run_hook_smart "unknown_cmd" '[]' ""
  assert_fallthrough
}

@test "pr: reentrancy guard exits before any work" {
  local json
  json=$(jq -n --arg cmd "rm -rf /" '{"tool_input":{"command":$cmd}}')
  SMART_APPROVE_ACTIVE=1 SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="" \
    run bash -c 'printf "%s" "$1" | "$2" --deny "$3"' \
      _ "$json" "$HOOK_SCRIPT" '["Bash(rm *)"]'
  # Even a denied command produces nothing under the guard
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "pr: CRLF in command input does not break deny matching" {
  local json
  json=$(jq -n --arg cmd $'rm -rf /\r' '{"tool_input":{"command":$cmd}}')
  SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="" SMART_APPROVE_ACTIVE= \
    run bash -c 'printf "%s" "$1" | "$2" --deny "$3"' \
      _ "$json" "$HOOK_SCRIPT" '["Bash(rm *)"]'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"behavior":"deny"'* ]]
}

@test "pr: hooks.json registers PermissionRequest for Bash" {
  run jq -e '.hooks.PermissionRequest[0].matcher == "Bash" and (.hooks | has("PreToolUse") | not)' \
    "${BATS_TEST_DIRNAME}/../hooks/hooks.json"
  [[ "$status" -eq 0 ]]
}

@test "pr: --deny presence suppresses real settings loading" {
  local TEST_DIR
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/home/.claude"
  # A deny rule that WOULD fire if settings were read
  echo '{"permissions":{"deny":["Bash(rm *)"]}}' > "$TEST_DIR/home/.claude/settings.json"
  local json
  json=$(jq -n --arg cmd "rm -rf /" '{"tool_input":{"command":$cmd}}')
  SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="" SMART_APPROVE_ACTIVE= \
  HOME="$TEST_DIR/home" \
    run bash -c 'printf "%s" "$1" | "$2" --deny "[]"' \
      _ "$json" "$HOOK_SCRIPT"
  # Empty --deny wins over the settings deny rule
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
  rm -rf "$TEST_DIR"
}

@test "pr: absent --deny reads settings deny rules" {
  local TEST_DIR
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/home/.claude"
  echo '{"permissions":{"deny":["Bash(rm *)"]}}' > "$TEST_DIR/home/.claude/settings.json"
  local json
  json=$(jq -n --arg cmd "rm -rf /" '{"tool_input":{"command":$cmd}}')
  SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="" SMART_APPROVE_ACTIVE= \
  HOME="$TEST_DIR/home" \
    run bash -c 'printf "%s" "$1" | "$2"' \
      _ "$json" "$HOOK_SCRIPT"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"behavior":"deny"'* ]]
  rm -rf "$TEST_DIR"
}
