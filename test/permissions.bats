#!/usr/bin/env bats
# Tests for permission matching logic.

load test_helper

# -- basic matching --

@test "perm: exact command match" {
  run_hook "ls" '["Bash(ls *)"]'
  assert_approved
}

@test "perm: command with args matches prefix" {
  run_hook "git status" '["Bash(git *)"]'
  assert_approved
}

@test "perm: unknown command falls through" {
  run_hook "evil_cmd" '["Bash(ls *)"]'
  assert_fallthrough
}

@test "perm: empty allow list falls through" {
  run_hook "ls" '[]'
  assert_fallthrough
}

# -- prefix matching edge cases --

@test "perm: git-evil does NOT match git prefix" {
  run_hook "git-evil" '["Bash(git *)"]'
  assert_fallthrough
}

@test "perm: gitx does NOT match git prefix" {
  run_hook "gitx status" '["Bash(git *)"]'
  assert_fallthrough
}

@test "perm: path separator matches (cmd/path)" {
  run_hook "./scripts/test.sh" '["Bash(./scripts *)"]'
  assert_approved
}

@test "perm: case sensitive - uppercase blocked" {
  run_hook "LS" '["Bash(ls *)"]'
  assert_fallthrough
}

# -- format support --

@test "perm: space-star format Bash(cmd *)" {
  run_hook "ls -la" '["Bash(ls *)"]'
  assert_approved
}

@test "perm: colon-star format Bash(cmd:*)" {
  run_hook "ls -la" '["Bash(ls:*)"]'
  assert_approved
}

@test "perm: bare-star format Bash(cmd*)" {
  run_hook "ls -la" '["Bash(ls*)"]'
  assert_approved
}

# -- multi-word prefixes --

@test "perm: multi-word prefix git log" {
  run_hook "git log --oneline" '["Bash(git log *)"]'
  assert_approved
}

@test "perm: multi-word prefix does not match other subcommand" {
  run_hook "git push" '["Bash(git log *)"]'
  assert_fallthrough
}

# -- env var stripping --

@test "perm: env var prefix stripped for matching" {
  run_hook "FOO=bar ls" '["Bash(ls *)"]'
  assert_approved
}

@test "perm: multiple env var prefixes stripped" {
  run_hook "FOO=1 BAR=2 ls" '["Bash(ls *)"]'
  assert_approved
}

# -- deny list --

@test "perm: deny takes precedence over allow" {
  run_hook "rm -rf /" '["Bash(rm *)"]' '["Bash(rm *)"]'
  assert_denied
}

@test "perm: deny blocks specific command" {
  run_hook "rm -rf /" '["Bash(rm *)"]' '["Bash(rm -rf *)"]'
  assert_denied
}

@test "perm: deny prefix does not block other commands" {
  run_hook "ls" '["Bash(ls *)","Bash(rm *)"]' '["Bash(rm *)"]'
  assert_approved
}

# -- compound command permissions --

@test "perm: pipe approved when all parts allowed" {
  run_hook "ls | grep foo" '["Bash(ls *)","Bash(grep *)"]'
  assert_approved
}

@test "perm: pipe blocked when one part not allowed" {
  run_hook "ls | evil_cmd" '["Bash(ls *)"]'
  assert_fallthrough
}

@test "perm: AND chain approved when all allowed" {
  run_hook "mkdir -p dir && cd dir" '["Bash(mkdir *)","Bash(cd *)"]'
  assert_approved
}

@test "perm: semicolon chain approved when all allowed" {
  run_hook "echo a; echo b" '["Bash(echo *)"]'
  assert_approved
}

@test "perm: compound falls through when part is unknown (not denied)" {
  run_hook "ls; unknown_cmd" '["Bash(ls *)"]'
  assert_fallthrough
}

# -- compound deny (actively blocked) --

@test "perm: compound denied when segment matches deny list" {
  run_hook "ls && rm -rf /" '["Bash(ls *)","Bash(rm *)"]' '["Bash(rm -rf *)"]'
  assert_denied
}

@test "perm: compound denied in pipe when segment matches deny list" {
  run_hook "cat file | rm -rf /" '["Bash(cat *)","Bash(rm *)"]' '["Bash(rm -rf *)"]'
  assert_denied
}

@test "perm: compound deny does not affect allowed-only compound" {
  run_hook "ls | grep foo" '["Bash(ls *)","Bash(grep *)"]' '["Bash(rm *)"]'
  assert_approved
}

# -- quoted env var stripping (I12) --

@test "perm: double-quoted env var stripped for matching" {
  run_hook 'FOO="bar baz" ls' '["Bash(ls *)"]'
  assert_approved
}

@test "perm: single-quoted env var stripped for matching" {
  run_hook "FOO='bar baz' ls" '["Bash(ls *)"]'
  assert_approved
}

# -- command wrapper stripping (I13) --

@test "perm: env wrapper stripped for matching" {
  run_hook "env ls -la" '["Bash(ls *)"]'
  assert_approved
}

@test "perm: nice wrapper stripped for matching" {
  run_hook "nice ls" '["Bash(ls *)"]'
  assert_approved
}

@test "perm: sudo wrapper stripped for matching" {
  run_hook "sudo ls" '["Bash(ls *)"]'
  assert_approved
}

@test "perm: multiple wrappers stripped" {
  run_hook "env sudo ls" '["Bash(ls *)"]'
  assert_approved
}
