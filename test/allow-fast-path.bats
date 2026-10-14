#!/usr/bin/env bats
# Tests for the Stage 1 allow fast path: a compound command whose every
# parsed segment matches an allow rule is approved locally, without an AI
# evaluation. The deny gate still runs first, so deny always wins. The fast
# path applies to compound commands only: natively allowed simple commands
# never reach the hook in the first place.

load test_helper

# -- approval when every segment is allowed --

@test "allow: compound of two allowed commands is approved" {
  run_hook_allow 'ls | grep foo' '["Bash(ls *)", "Bash(grep *)"]'
  assert_approved
}

@test "allow: compound chain with all segments allowed" {
  run_hook_allow 'git status && git log --oneline' '["Bash(git *)"]'
  assert_approved
}

@test "allow: env-prefixed segment matches allow rule" {
  run_hook_allow 'FOO=1 ls | grep x' '["Bash(ls *)", "Bash(grep *)"]'
  assert_approved
}

@test "allow: colon-star allow format works" {
  run_hook_allow 'git status; git log' '["Bash(git:*)"]'
  assert_approved
}

@test "allow: bare-star allow format works" {
  run_hook_allow 'git status | head -3' '["Bash(git*)", "Bash(head *)"]'
  assert_approved
}

# -- exact rules match exactly --

@test "allow: exact rule Bash(git status) approves exact repetition" {
  run_hook_allow 'git status; git status' '["Bash(git status)"]'
  assert_approved
}

@test "allow: exact rule does not approve other arguments" {
  run_hook_allow 'git status; git log' '["Bash(git status)"]'
  assert_fallthrough
}

# -- refusal when any segment is not allowed --

@test "allow: one unallowed segment blocks fast path" {
  run_hook_allow 'ls | python3 -c pass' '["Bash(ls *)"]'
  assert_fallthrough
}

@test "allow: empty allow list falls through" {
  run_hook_allow 'ls | grep foo' '[]'
  assert_fallthrough
}

@test "allow: non-Bash allow rules are ignored" {
  run_hook_allow 'ls | grep foo' '["Read", "WebFetch(*)", "Bash(ls *)"]'
  assert_fallthrough
}

# -- substitution contents must be allowed too --

@test "allow: command substitution content must match an allow rule" {
  run_hook_allow 'echo $(ls)' '["Bash(echo *)"]'
  assert_fallthrough
}

@test "allow: command substitution allowed when its command is allowed" {
  run_hook_allow 'echo $(ls)' '["Bash(echo *)", "Bash(ls *)"]'
  assert_approved
}

# -- wrapper stripping: the stripped inner command must be allowed --

@test "allow: xargs wrapper exposes the inner command" {
  run_hook_allow 'ls | xargs rm -rf /tmp/x' '["Bash(ls *)"]'
  assert_fallthrough
}

# -- deny still wins --

@test "allow: deny gate runs before the allow fast path" {
  run_hook_allow 'ls; rm -rf /' '["Bash(ls *)", "Bash(rm *)"]' '["Bash(rm *)"]'
  assert_denied
}

# -- scope: compound only --

@test "allow: simple commands do not use the fast path" {
  run_hook_allow 'ls' '["Bash(ls *)"]'
  assert_fallthrough
}

# -- logging --

@test "allow: fast-path approval is logged to the Stage 1 log" {
  local log json
  log=$(mktemp)
  json=$(jq -n --arg cmd 'ls | grep foo' '{"tool_input":{"command":$cmd}}')
  SMART_APPROVE_ENABLED=false SMART_APPROVE_ACTIVE= \
  AUTO_APPROVE_LOG_FILE="$log" \
    run bash -c 'printf "%s" "$1" | "$2" --deny "[]" --allow "[\"Bash(ls *)\", \"Bash(grep *)\"]"' \
    _ "$json" "$HOOK_SCRIPT"
  assert_approved
  run jq -r '.decision' "$log"
  [ "$output" = "allow" ]
  rm -f "$log"
}
