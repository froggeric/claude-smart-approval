#!/usr/bin/env bats
# Tests for Stage 1 decision logging in auto-approve.sh (deny-only: allow
# decisions come from Stage 2 and are logged by smart-approve.sh)

load test_helper

# Run the hook with logging enabled, capturing log to a temp file.
# $1 = command, $2 = deny JSON (optional, defaults '[]'). Always passed so
# real settings files are never read (hermeticity).
run_hook_logged() {
  local command="$1"
  local deny="${2:-[]}"
  _LOG_FILE=$(mktemp)
  rm -f "$_LOG_FILE"
  local json
  json=$(jq -n --arg cmd "$command" '{"tool_input":{"command":$cmd}}')
  SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="$_LOG_FILE" \
  SMART_APPROVE_ACTIVE= \
    run bash -c 'printf "%s" "$1" | "$2" --deny "$3"' \
      _ "$json" "$HOOK_SCRIPT" "$deny"
}

teardown() {
  [[ -n "${_LOG_FILE:-}" ]] && [[ -f "$_LOG_FILE" ]] && rm -f "$_LOG_FILE" || true
}

# -- deny logging --

@test "log-s1: simple deny creates log entry" {
  run_hook_logged "rm -rf /" '["Bash(rm *)"]'
  [[ -f "$_LOG_FILE" ]]
  local entry
  entry=$(<"$_LOG_FILE")
  [[ "$entry" == *'"decision":"deny"'* ]]
  [[ "$entry" == *'"matched_prefix":"rm"'* ]]
  [[ "$entry" == *'"type":"simple"'* ]]
}

@test "log-s1: compound deny creates log entry" {
  run_hook_logged "ls && rm -rf /" '["Bash(rm -rf *)"]'
  [[ -f "$_LOG_FILE" ]]
  local entry
  entry=$(<"$_LOG_FILE")
  [[ "$entry" == *'"decision":"deny"'* ]]
  [[ "$entry" == *'"type":"compound"'* ]]
}

# -- field validation --

@test "log-s1: entry is valid JSON with required fields" {
  run_hook_logged "git push --force" '["Bash(git push --force *)"]'
  [[ -f "$_LOG_FILE" ]]
  run jq '.' "$_LOG_FILE"
  [[ "$status" -eq 0 ]]
  run jq -r '.ts' "$_LOG_FILE"
  [[ "$output" != "" ]] && [[ "$output" != "null" ]]
  run jq -r '.cmd' "$_LOG_FILE"
  [[ "$output" == "git push --force" ]]
  run jq -r '.decision' "$_LOG_FILE"
  [[ "$output" == "deny" ]]
  run jq -r '.matched_prefix' "$_LOG_FILE"
  [[ "$output" == "git push --force" ]]
  run jq -r '.type' "$_LOG_FILE"
  [[ "$output" == "simple" ]]
}

# -- matched_prefix capture --

@test "log-s1: matched_prefix captures deny prefix for denied compound" {
  run_hook_logged "cat file | rm -rf /" '["Bash(rm -rf *)"]'
  [[ -f "$_LOG_FILE" ]]
  run jq -r '.matched_prefix' "$_LOG_FILE"
  [[ "$output" == "rm -rf" ]]
}

# -- fall-through produces no entry --

@test "log-s1: non-denied simple command produces no entry" {
  run_hook_logged "ls -la" '[]'
  [[ ! -f "$_LOG_FILE" ]] || [[ ! -s "$_LOG_FILE" ]]
}

@test "log-s1: non-denied compound produces no entry" {
  run_hook_logged "ls | grep foo" '[]'
  [[ ! -f "$_LOG_FILE" ]] || [[ ! -s "$_LOG_FILE" ]]
}

@test "log-s1: unknown command produces no Stage 1 log entry" {
  run_hook_logged "unknown_cmd" '[]'
  [[ ! -f "$_LOG_FILE" ]] || [[ ! -s "$_LOG_FILE" ]]
}

# -- rotation --

@test "log-s1: rotation trims old entries" {
  _LOG_FILE=$(mktemp)
  # Pre-fill with 3 lines
  for i in 1 2 3; do
    echo '{"ts":"old","cmd":"old","decision":"deny","matched_prefix":"x","type":"simple"}' >> "$_LOG_FILE"
  done
  local json
  json=$(jq -n --arg cmd "rm -rf x" '{"tool_input":{"command":$cmd}}')
  # Max 3 lines — adding one more (via a deny hit) should trigger rotation
  SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="$_LOG_FILE" AUTO_APPROVE_LOG_MAX_LINES=3 \
  SMART_APPROVE_ACTIVE= \
    run bash -c 'printf "%s" "$1" | "$2" --deny "$3"' \
      _ "$json" "$HOOK_SCRIPT" '["Bash(rm *)"]'
  local line_count
  line_count=$(wc -l < "$_LOG_FILE" | tr -d ' ')
  [[ "$line_count" -le 3 ]]
}

# -- disable via empty var --

@test "log-s1: empty AUTO_APPROVE_LOG_FILE disables logging" {
  _LOG_FILE=""  # Prevent teardown from trying to remove a file from another test
  local json
  json=$(jq -n --arg cmd "rm -rf x" '{"tool_input":{"command":$cmd}}')
  local check_file="$BATS_TEST_TMPDIR/check-log"
  rm -f "$check_file"
  SMART_APPROVE_ENABLED=false AUTO_APPROVE_LOG_FILE="" \
  SMART_APPROVE_ACTIVE= \
    run bash -c 'printf "%s" "$1" | "$2" --deny "$3"' \
      _ "$json" "$HOOK_SCRIPT" '["Bash(rm *)"]'
  [[ ! -f "$check_file" ]]
}
