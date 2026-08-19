#!/usr/bin/env bats
# Tests for deny-list matching logic. Stage 1 is a deny gate: allows are
# Stage 2's job (see smart-integration.bats). The single argument to run_hook
# is the DENY list.

load test_helper

# -- basic deny matching --

@test "perm: deny exact command" {
  run_hook "rm" '["Bash(rm)"]'
  assert_denied
}

@test "perm: deny command with args matches prefix" {
  run_hook "rm -rf /tmp/x" '["Bash(rm *)"]'
  assert_denied
}

@test "perm: command not in deny list falls through" {
  run_hook "ls" '["Bash(rm *)"]'
  assert_fallthrough
}

@test "perm: empty deny list falls through" {
  run_hook "ls" '[]'
  assert_fallthrough
}

# -- prefix matching edge cases (deny side) --

@test "perm: specific deny prefix does not block other subcommands" {
  run_hook "git status" '["Bash(git push --force *)"]'
  assert_fallthrough
}

@test "perm: git-evil does NOT match git deny prefix" {
  run_hook "git-evil" '["Bash(git *)"]'
  assert_fallthrough
}

@test "perm: gitx does NOT match git deny prefix" {
  run_hook "gitx status" '["Bash(git *)"]'
  assert_fallthrough
}

@test "perm: case sensitive deny" {
  run_hook "RM -rf /" '["Bash(rm *)"]'
  assert_fallthrough
}

@test "perm: path separator matches in deny (cmd/path)" {
  run_hook "./scripts/test.sh" '["Bash(./scripts *)"]'
  assert_denied
}

# -- format support --

@test "perm: space-star format Bash(rm *)" {
  run_hook "rm -rf x" '["Bash(rm *)"]'
  assert_denied
}

@test "perm: colon-star format Bash(rm:*)" {
  run_hook "rm -rf x" '["Bash(rm:*)"]'
  assert_denied
}

@test "perm: bare-star format Bash(rm*)" {
  run_hook "rm -rf x" '["Bash(rm*)"]'
  assert_denied
}

# -- multi-word deny prefixes --

@test "perm: multi-word deny prefix git push" {
  run_hook "git push --force origin" '["Bash(git push *)"]'
  assert_denied
}

@test "perm: multi-word deny does not match other subcommand" {
  run_hook "git log" '["Bash(git push *)"]'
  assert_fallthrough
}

# -- env var stripping (deny side, I12) --

@test "perm: env var prefix stripped for deny matching" {
  run_hook "FOO=bar rm -rf /tmp" '["Bash(rm *)"]'
  assert_denied
}

@test "perm: double-quoted env var stripped for deny matching" {
  run_hook 'FOO="bar baz" rm -rf x' '["Bash(rm *)"]'
  assert_denied
}

@test "perm: single-quoted env var stripped for deny matching" {
  run_hook "FOO='bar baz' rm -rf x" '["Bash(rm *)"]'
  assert_denied
}

# -- command wrapper stripping (deny side, I13) --

@test "perm: env wrapper stripped for deny matching" {
  run_hook "env rm -rf /tmp" '["Bash(rm *)"]'
  assert_denied
}

@test "perm: nice wrapper stripped for deny matching" {
  run_hook "nice rm x" '["Bash(rm *)"]'
  assert_denied
}

@test "perm: sudo wrapper stripped for deny matching" {
  run_hook "sudo rm -rf /tmp" '["Bash(rm *)"]'
  assert_denied
}

@test "perm: multiple wrappers stripped for deny matching" {
  run_hook "env sudo rm -rf /tmp" '["Bash(rm *)"]'
  assert_denied
}

# -- compound command deny --

@test "perm: compound denied when segment matches deny list" {
  run_hook "ls && rm -rf /" '["Bash(rm -rf *)"]'
  assert_denied
}

@test "perm: compound denied in pipe when segment matches deny list" {
  run_hook "cat file | rm -rf /" '["Bash(rm -rf *)"]'
  assert_denied
}

@test "perm: subshell with denied command blocked" {
  run_hook "(ls; rm -rf /)" '["Bash(rm -rf *)"]'
  assert_denied
}

@test "perm: compound without denied segment falls through" {
  run_hook "ls | grep foo" '["Bash(rm *)"]'
  assert_fallthrough
}

@test "perm: compound with unknown segment falls through (not denied)" {
  run_hook "ls; unknown_cmd" '["Bash(rm *)"]'
  assert_fallthrough
}
