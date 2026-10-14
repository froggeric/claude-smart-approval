#!/usr/bin/env bats
# Integration tests for Stage 2 smart approval in the main hook

load test_helper

@test "int: simple unknown command triggers smart approval (approve)" {
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"approve\",\"reason\":\"safe\",\"pattern\":\"Bash(curl *)\",\"scope\":\"global\"}","cost_usd":0.001}'
  run_hook_smart "curl https://example.com" '[]' "$mock_resp"
  [[ "$output" == *'"behavior":"allow"'* ]]
}

@test "int: simple unknown command triggers smart approval (deny)" {
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"deny\",\"reason\":\"dangerous\"}","cost_usd":0.001}'
  run_hook_smart "rm -rf /tmp/test" '[]' "$mock_resp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"behavior":"deny"'* ]]
}

@test "int: unknown compound ask emits nothing (native prompt)" {
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"ask\",\"reason\":\"uncertain\"}","cost_usd":0.001}'
  run_hook_smart "ls; unknown_cmd" '[]' "$mock_resp"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "int: non-denied compound reaches Stage 2" {
  # No allow fast path anymore: every non-denied command goes to the AI tier
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"approve\",\"reason\":\"safe\",\"pattern\":\"Bash(ls *)\",\"scope\":\"global\"}","cost_usd":0.001}'
  run_hook_smart "ls | grep foo" '[]' "$mock_resp"
  [[ "$output" == *'"behavior":"allow"'* ]]
}

@test "int: denied compound skips smart approval" {
  # Contains denied segment — denied without calling claude
  run_hook "ls && rm -rf /" '["Bash(rm -rf *)"]'
  assert_denied
}

@test "int: SMART_APPROVE_ENABLED=false skips Stage 2" {
  # run_hook disables smart approval by default, so unknown cmd falls through
  run_hook "unknown_cmd" '[]'
  assert_fallthrough
}

@test "int: smart approval failure falls through gracefully" {
  # Mock returns empty output — should fall through to native prompt
  run_hook_smart "unknown_cmd" '[]' ""
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
  SMART_APPROVE_ACTIVE= \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_resp" \
  HOME="$home_dir" \
  AUTO_APPROVE_LOG_FILE="" \
    run bash -c 'printf "%s" "$1" | "$2" --deny "[]"' \
      _ "$json" "$HOOK_SCRIPT"

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
  SMART_APPROVE_ACTIVE= \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_resp" \
  HOME="$home_dir" \
  AUTO_APPROVE_LOG_FILE="" \
    run bash -c 'printf "%s" "$1" | "$2" --deny "[]"' \
      _ "$json" "$HOOK_SCRIPT"

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
  SMART_APPROVE_ACTIVE= \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_resp" \
  HOME="$home_dir" \
  AUTO_APPROVE_LOG_FILE="" \
    run bash -c 'printf "%s" "$1" | "$2" --deny "[]"' \
      _ "$json" "$HOOK_SCRIPT"

  local count
  count=$(jq '.permissions.allow | length' "$home_dir/.claude/settings.local.json")
  [[ "$count" -eq 0 ]]

  rm -rf "$TEST_DIR"
  cleanup_mocks
}

# -- deny list override prevention (C2) --

@test "int: simple denied command NOT overridden by AI approve" {
  # rm is on deny list but AI mock says approve — must still be denied
  local mock_resp
  mock_resp='{"type":"result","result":"{\"decision\":\"approve\",\"reason\":\"seems safe\",\"pattern\":\"Bash(rm *)\",\"scope\":\"project\"}","cost_usd":0.001}'
  run_hook_smart "rm -rf /tmp/test" '["Bash(rm *)"]' "$mock_resp"
  # Deny list wins (C2): deny decision object on stdout, exit 0
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'"behavior":"deny"'* ]]
}

# -- nested session pinning --

@test "int: nested claude session is pinned against global settings" {
  # Every nested claude reads the user's settings at startup, so a global
  # CLAUDE_CODE_EFFORT_LEVEL=max or ultracode:true would apply to this
  # one-shot classifier: slower evaluations, timeout-driven prompts, and in
  # the ultracode case an attempt to plan workflows inside a --max-turns 1
  # call. The invocation must pin effort low and ultracode off.
  local TEST_DIR args_file mock_cmd json mock_resp
  TEST_DIR=$(mktemp -d)
  args_file="$TEST_DIR/args"
  mock_resp='{"type":"result","result":"{\"decision\":\"ask\",\"reason\":\"x\"}","cost_usd":0.001}'
  mock_cmd="$TEST_DIR/mock-claude"
  cat > "$mock_cmd" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_ARGS"
printf '%s' "$MOCK_RESPONSE"
MOCKEOF
  chmod +x "$mock_cmd"

  json=$(jq -n --arg cmd "unknown_cmd" '{"tool_input":{"command":$cmd}}')
  SMART_APPROVE_ENABLED=true SMART_APPROVE_AUTO_LEARN=false \
  SMART_APPROVE_ACTIVE= \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_resp" CAPTURE_ARGS="$args_file" \
  AUTO_APPROVE_LOG_FILE="" \
    run bash -c 'printf "%s" "$1" | "$2" --deny "[]"' \
      _ "$json" "$HOOK_SCRIPT"

  [[ -s "$args_file" ]] || {
    echo "# nested claude was never invoked" >&3
    rm -rf "$TEST_DIR"
    return 1
  }
  local settings_arg
  settings_arg=$(grep -o '{"disableAllHooks".*}' "$args_file" | head -1)
  [[ "$settings_arg" == *'"ultracode":false'* ]] || {
    echo "# ultracode not pinned off in: $settings_arg" >&3
    rm -rf "$TEST_DIR"
    return 1
  }
  [[ "$settings_arg" == *'"CLAUDE_CODE_EFFORT_LEVEL":"low"'* ]] || {
    echo "# effort not pinned low in: $settings_arg" >&3
    rm -rf "$TEST_DIR"
    return 1
  }
  [[ "$settings_arg" == *'"CLAUDE_CODE_DISABLE_CLAUDE_MDS":"1"'* ]] || {
    echo "# CLAUDE.md loading not disabled in: $settings_arg" >&3
    rm -rf "$TEST_DIR"
    return 1
  }
  [[ "$settings_arg" == *'"CLAUDE_CODE_DISABLE_AUTO_MEMORY":"1"'* ]] || {
    echo "# auto memory not disabled in: $settings_arg" >&3
    rm -rf "$TEST_DIR"
    return 1
  }
  local flags_expected=(--disable-slash-commands --strict-mcp-config)
  local flag
  for flag in "${flags_expected[@]}"; do
    grep -qx -- "$flag" "$args_file" || {
      echo "# missing flag: $flag" >&3
      rm -rf "$TEST_DIR"
      return 1
    }
  done
  grep -q '{"mcpServers":{}}' "$args_file" || {
    echo "# missing empty --mcp-config" >&3
    rm -rf "$TEST_DIR"
    return 1
  }
  rm -rf "$TEST_DIR"
}
