#!/usr/bin/env bash
# Shared helpers for BATS tests of auto-approve.sh
#
# Two test layers:
#   run_parse  "cmd"            -> test command extraction (no permissions)
#   run_hook   "cmd" [DENY]     -> test Stage 1 deny gate (stdin JSON + deny list)
#
# run_hook ALWAYS passes --deny (even '[]'): the flag's presence suppresses
# real-settings loading, keeping tests hermetic. Allow decisions are only
# produced by Stage 2 — see run_hook_smart.

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

# Run the Stage 1 hook with a deny list.
# $1 = command string
# $2 = (optional) deny list as JSON array, e.g. '["Bash(rm *)"]' — defaults to
#      '[]'. Always passed so real settings files are never read (hermeticity).
run_hook() {
  local command="$1"
  local deny="${2:-[]}"
  local json
  json=$(jq -n --arg cmd "$command" '{"tool_input":{"command":$cmd}}')
  # Stage 1 only — disable smart approval by default
  SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="" \
  SMART_APPROVE_ACTIVE= \
    run bash -c 'printf "%s" "$1" | "$2" --deny "$3"' \
      _ "$json" "$HOOK_SCRIPT" "$deny"
}

# Assert hook output is an allow decision (only Stage 2 produces allows).
assert_approved() {
  [[ "$status" -eq 0 ]] || {
    echo "# expected ALLOW (exit 0), got exit $status" >&3
    return 1
  }
  [[ "$output" == *'"behavior":"allow"'* ]] || {
    echo "# expected ALLOW output, got: $output" >&3
    return 1
  }
}

# Assert hook emitted no decision at all (falls through to the native prompt).
assert_fallthrough() {
  [[ "$status" -eq 0 ]] || {
    echo "# expected FALLTHROUGH (exit 0), got exit $status" >&3
    return 1
  }
  [[ -z "$output" ]] || {
    echo "# expected FALLTHROUGH (empty stdout), got: $output" >&3
    return 1
  }
}

# Assert hook actively denied the command (stdout decision object, exit 0).
assert_denied() {
  [[ "$status" -eq 0 ]] || {
    echo "# expected DENY (exit 0), got exit $status with output: $output" >&3
    return 1
  }
  [[ "$output" == *'"behavior":"deny"'* ]] || {
    echo "# expected DENY decision in output, got: $output" >&3
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
# $1 = command, $2 = deny JSON (optional, defaults '[]'), $3 = mock response
run_hook_smart() {
  local command="$1"
  local deny="${2:-[]}"
  local mock_response="$3"
  local mock_cmd
  mock_cmd=$(create_mock_claude "$mock_response")

  local json
  json=$(jq -n --arg cmd "$command" '{"tool_input":{"command":$cmd}}')

  SMART_APPROVE_ENABLED=true SMART_APPROVE_AUTO_LEARN=false \
  SMART_APPROVE_ACTIVE= \
  AUTO_APPROVE_LOG_FILE="" \
  CLAUDE_CMD="$mock_cmd" MOCK_RESPONSE="$mock_response" \
    run bash -c 'printf "%s" "$1" | "$2" --deny "$3"' \
      _ "$json" "$HOOK_SCRIPT" "$deny"
}
