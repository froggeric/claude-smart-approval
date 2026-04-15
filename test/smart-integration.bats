#!/usr/bin/env bats
# Integration tests for Stage 2 smart approval in the main hook

load test_helper

@test "int: simple unknown command triggers smart approval (approve)" {
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"approve\",\"reason\":\"safe\",\"pattern\":\"Bash(curl *)\",\"scope\":\"global\"}","cost_usd":0.001}'
  run_hook_smart "curl https://example.com" '["Bash(ls *)"]' '[]' "$mock_resp"
  [[ "$output" == *'"permissionDecision":"allow"'* ]]
}

@test "int: simple unknown command triggers smart approval (deny)" {
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"deny\",\"reason\":\"dangerous\"}","cost_usd":0.001}'
  run_hook_smart "rm -rf /tmp/test" '["Bash(ls *)"]' '[]' "$mock_resp"
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "int: compound unknown command triggers smart approval (ask)" {
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"ask\",\"reason\":\"uncertain\"}","cost_usd":0.001}'
  run_hook_smart "ls; unknown_cmd" '["Bash(ls *)"]' '[]' "$mock_resp"
  [[ "$output" == *'"permissionDecision":"ask"'* ]]
}

@test "int: allowed compound skips smart approval" {
  # ls and grep are both allowed — should approve without calling claude
  run_hook "ls | grep foo" '["Bash(ls *)","Bash(grep *)"]'
  assert_approved
}

@test "int: denied compound skips smart approval" {
  # Contains denied segment — should deny without calling claude
  run_hook "ls && rm -rf /" '["Bash(ls *)","Bash(rm *)"]' '["Bash(rm -rf *)"]'
  assert_denied
}

@test "int: SMART_APPROVE_ENABLED=false skips Stage 2" {
  # run_hook disables smart approval by default, so unknown cmd falls through
  run_hook "unknown_cmd" '["Bash(ls *)"]'
  assert_fallthrough
}

@test "int: smart approval failure falls through gracefully" {
  # Mock returns empty output — should fall through to native prompt
  run_hook_smart "unknown_cmd" '["Bash(ls *)"]' '[]' ""
  assert_fallthrough
}

@test "int: auto-learn writes pattern on approval" {
  local TEST_DIR
  TEST_DIR=$(mktemp -d)
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"approve\",\"reason\":\"safe\",\"pattern\":\"Bash(curl *)\",\"scope\":\"global\"}","cost_usd":0.001}'
  local mock_cmd
  mock_cmd=$(create_mock_claude "$mock_resp")

  local json
  json=$(jq -n --arg cmd "curl https://example.com" '{"tool_input":{"command":$cmd}}')

  local home_dir="$TEST_DIR/home"
  mkdir -p "$home_dir/.claude"
  echo '{"permissions":{"allow":[]}}' > "$home_dir/.claude/settings.local.json"

  SMART_APPROVE_ENABLED=true SMART_APPROVE_AUTO_LEARN=true \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_resp" \
  HOME="$home_dir" \
  run bash -c 'printf "%s" "$1" | "$2" --permissions "$3"' \
    _ "$json" "$HOOK_SCRIPT" '["Bash(ls *)"]'

  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$home_dir/.claude/settings.local.json")
  [[ "$patterns" == "Bash(curl *)" ]]

  rm -rf "$TEST_DIR"
  cleanup_mocks
}

@test "int: auto-learn does not trigger on deny" {
  local TEST_DIR
  TEST_DIR=$(mktemp -d)
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"deny\",\"reason\":\"dangerous\"}","cost_usd":0.001}'
  local mock_cmd
  mock_cmd=$(create_mock_claude "$mock_resp")

  local json
  json=$(jq -n --arg cmd "rm -rf /tmp" '{"tool_input":{"command":$cmd}}')

  local home_dir="$TEST_DIR/home"
  mkdir -p "$home_dir/.claude"
  echo '{"permissions":{"allow":[]}}' > "$home_dir/.claude/settings.local.json"

  SMART_APPROVE_ENABLED=true SMART_APPROVE_AUTO_LEARN=true \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_resp" \
  HOME="$home_dir" \
  run bash -c 'printf "%s" "$1" | "$2" --permissions "$3"' \
    _ "$json" "$HOOK_SCRIPT" '["Bash(ls *)"]'

  local count
  count=$(jq '.permissions.allow | length' "$home_dir/.claude/settings.local.json")
  [[ "$count" -eq 0 ]]

  rm -rf "$TEST_DIR"
  cleanup_mocks
}

@test "int: auto-learn does not trigger on ask" {
  local TEST_DIR
  TEST_DIR=$(mktemp -d)
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"ask\",\"reason\":\"uncertain\"}","cost_usd":0.001}'
  local mock_cmd
  mock_cmd=$(create_mock_claude "$mock_resp")

  local json
  json=$(jq -n --arg cmd "unknown_cmd" '{"tool_input":{"command":$cmd}}')

  local home_dir="$TEST_DIR/home"
  mkdir -p "$home_dir/.claude"
  echo '{"permissions":{"allow":[]}}' > "$home_dir/.claude/settings.local.json"

  SMART_APPROVE_ENABLED=true SMART_APPROVE_AUTO_LEARN=true \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_resp" \
  HOME="$home_dir" \
  run bash -c 'printf "%s" "$1" | "$2" --permissions "$3"' \
    _ "$json" "$HOOK_SCRIPT" '["Bash(ls *)"]'

  local count
  count=$(jq '.permissions.allow | length' "$home_dir/.claude/settings.local.json")
  [[ "$count" -eq 0 ]]

  rm -rf "$TEST_DIR"
  cleanup_mocks
}
