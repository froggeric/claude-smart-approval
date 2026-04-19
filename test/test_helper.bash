#!/usr/bin/env bash
# Shared helpers for BATS tests of auto-approve.sh
#
# Two test layers:
#   run_parse  "cmd"              -> test command extraction (no permissions)
#   run_hook   "cmd" ALLOW [DENY] -> test full hook pipeline (stdin JSON + permissions)

HOOK_SCRIPT="${BATS_TEST_DIRNAME}/../auto-approve.sh"

# ---------------------------------------------------------------------------
# Parsing helpers (plain text stdin -> extracted commands on stdout)
# ---------------------------------------------------------------------------

# Feed a command string to `parse` mode, capture extracted commands.
run_parse() {
  run bash -c 'printf "%s" "$1" | "$2" parse' _ "$1" "$HOOK_SCRIPT"
}

# Assert extracted commands match expected list (order matters).
# Usage: assert_commands "ls" "grep foo" "head -5"
assert_commands() {
  local -a expected=("$@")
  local -a actual=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && actual+=("$line")
  done <<< "$output"

  if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
    echo "# count: expected ${#expected[@]}, got ${#actual[@]}" >&3
    echo "# expected: $(printf "'%s' " "${expected[@]}")" >&3
    echo "# actual:   $(printf "'%s' " "${actual[@]}")" >&3
    return 1
  fi
  for i in "${!expected[@]}"; do
    if [[ "${actual[$i]}" != "${expected[$i]}" ]]; then
      echo "# command[$i]: expected '${expected[$i]}', got '${actual[$i]}'" >&3
      return 1
    fi
  done
}

assert_no_commands() {
  [[ -z "$output" ]] || {
    echo "# expected no output, got: $output" >&3
    return 1
  }
}

# ---------------------------------------------------------------------------
# Hook helpers (JSON stdin -> permission decision on stdout)
# ---------------------------------------------------------------------------

# Run the full hook with custom permissions.
# $1 = command string
# $2 = allow list as JSON array, e.g. '["Bash(ls *)","Bash(grep *)"]'
# $3 = (optional) deny list as JSON array
run_hook() {
  local command="$1"
  local allow="${2:-[]}"
  local deny="${3:-[]}"
  local json
  json=$(jq -n --arg cmd "$command" '{"tool_input":{"command":$cmd}}')
  # Existing tests expect Stage 1 only — disable smart approval by default
  if [[ "$deny" == "[]" ]]; then
    SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="" run bash -c 'printf "%s" "$1" | "$2" --permissions "$3"' \
      _ "$json" "$HOOK_SCRIPT" "$allow"
  else
    SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="" run bash -c 'printf "%s" "$1" | "$2" --permissions "$3" --deny "$4"' \
      _ "$json" "$HOOK_SCRIPT" "$allow" "$deny"
  fi
}

# Assert hook output is an allow decision.
assert_approved() {
  [[ "$output" == *'"permissionDecision":"allow"'* ]] || {
    echo "# expected ALLOW, got: $output" >&3
    return 1
  }
}

# Assert hook did NOT output an allow decision (fell through).
assert_fallthrough() {
  [[ "$status" -eq 0 ]] || {
    echo "# expected FALLTHROUGH (exit 0), got exit $status" >&3
    return 1
  }
  [[ "$output" != *'"permissionDecision":"allow"'* ]] || {
    echo "# expected FALLTHROUGH (no output), got: $output" >&3
    return 1
  }
}

# Assert hook actively denied the command (exit 2).
assert_denied() {
  [[ "$status" -eq 2 ]] || {
    echo "# expected DENY (exit 2), got exit $status with output: $output" >&3
    return 1
  }
}

# ---------------------------------------------------------------------------
# Smart approval helpers
# ---------------------------------------------------------------------------

# Create a mock claude command that returns a predefined response.
# Uses environment variable to pass response — avoids heredoc expansion issues.
# Registers mock path for automatic cleanup in teardown.
# Returns: path to mock script
MOCK_FILES=()

create_mock_claude() {
  local mock
  mock=$(mktemp)
  chmod +x "$mock"
  # Write mock script using quoted heredoc to prevent any shell expansion.
  # The response is passed via MOCK_RESPONSE env var at execution time.
  cat > "$mock" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s' "$MOCK_RESPONSE"
MOCKEOF
  MOCK_FILES+=("$mock")
  printf '%s' "$mock"
}

cleanup_mocks() {
  for f in "${MOCK_FILES[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
  MOCK_FILES=()
}

# Run the full hook with smart approval enabled and a mocked claude.
# $1 = command, $2 = allow JSON, $3 = deny JSON (optional), $4 = mock response
run_hook_smart() {
  local command="$1"
  local allow="${2:-[]}"
  local deny="${3:-[]}"
  local mock_response="$4"
  local mock_cmd
  mock_cmd=$(create_mock_claude "$mock_response")

  local json
  json=$(jq -n --arg cmd "$command" '{"tool_input":{"command":$cmd}}')

  SMART_APPROVE_ENABLED=true SMART_APPROVE_AUTO_LEARN=false \
  AUTO_APPROVE_LOG_FILE="" \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_response" \
  run bash -c 'printf "%s" "$1" | "$2" --permissions "$3" --deny "$4"' \
    _ "$json" "$HOOK_SCRIPT" "$allow" "$deny"
}
