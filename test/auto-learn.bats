#!/usr/bin/env bats
# Tests for auto-learn.sh — pattern auto-learning to settings files

load test_helper

LEARN_SCRIPT="${BATS_TEST_DIRNAME}/../auto-learn.sh"

setup() {
  TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME/.claude"
  echo '{"permissions":{"allow":[]}}' > "$HOME/.claude/settings.local.json"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# -- pattern normalization --

@test "learn: normalizes pattern with Bash() wrapper" {
  run bash -c '"$1" --pattern "Bash(git status *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(git status *)" ]]
}

@test "learn: wraps bare pattern in Bash()" {
  run bash -c '"$1" --pattern "git status *" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(git status *)" ]]
}

@test "learn: adds star suffix to bare command" {
  run bash -c '"$1" --pattern "Bash(git status)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(git status *)" ]]
}

@test "learn: adds star suffix to multi-word command without star" {
  run bash -c '"$1" --pattern "npm test" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(npm test *)" ]]
}

@test "learn: preserves existing star on single command" {
  run bash -c '"$1" --pattern "Bash(ls *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(ls *)" ]]
}

# -- scope routing --

@test "learn: global scope writes to home settings" {
  run bash -c '"$1" --pattern "Bash(ls *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  [[ -f "$HOME/.claude/settings.local.json" ]]
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(ls *)" ]]
}

@test "learn: project scope writes to project settings" {
  local project_dir="$TEST_DIR/project"
  mkdir -p "$project_dir/.claude"
  echo '{"permissions":{"allow":[]}}' > "$project_dir/.claude/settings.local.json"

  run bash -c '"$1" --pattern "Bash(npm test *)" --scope project --root "$2"' \
    _ "$LEARN_SCRIPT" "$project_dir"
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$project_dir/.claude/settings.local.json")
  [[ "$patterns" == "Bash(npm test *)" ]]
}

# -- deduplication --

@test "learn: does not duplicate existing pattern" {
  echo '{"permissions":{"allow":["Bash(ls *)"]}}' > "$HOME/.claude/settings.local.json"
  run bash -c '"$1" --pattern "Bash(ls *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json")
  [[ "$count" -eq 1 ]]
}

@test "learn: does not add pattern if already in global settings.json" {
  echo '{"permissions":{"allow":["Bash(git *)"]}}' > "$HOME/.claude/settings.json"
  echo '{"permissions":{"allow":[]}}' > "$HOME/.claude/settings.local.json"
  run bash -c '"$1" --pattern "Bash(git *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  # Should not be added to settings.local.json since it's already in settings.json
  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json")
  [[ "$count" -eq 0 ]]
}

# -- file creation --

@test "learn: creates settings file if it does not exist" {
  rm -f "$HOME/.claude/settings.local.json"
  run bash -c '"$1" --pattern "Bash(make *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  [[ -f "$HOME/.claude/settings.local.json" ]]
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(make *)" ]]
}

# -- edge cases --

@test "learn: empty pattern does nothing" {
  run bash -c '"$1" --pattern "" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json")
  [[ "$count" -eq 0 ]]
}

@test "learn: project scope with no .claude dir creates it" {
  local project_dir="$TEST_DIR/project"
  mkdir -p "$project_dir"
  # No .claude directory exists
  run bash -c '"$1" --pattern "Bash(npm run *)" --scope project --root "$2"' \
    _ "$LEARN_SCRIPT" "$project_dir"
  [[ -f "$project_dir/.claude/settings.local.json" ]]
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$project_dir/.claude/settings.local.json")
  [[ "$patterns" == "Bash(npm run *)" ]]
}

# -- pattern validation --

@test "learn: rejects overly broad pattern Bash(* *)" {
  run bash -c '"$1" --pattern "*" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json" 2>/dev/null) || count=0
  [[ "$count" -eq 0 ]]
}

@test "learn: rejects dangerous command rm" {
  run bash -c '"$1" --pattern "Bash(rm -rf *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json" 2>/dev/null) || count=0
  [[ "$count" -eq 0 ]]
}

@test "learn: rejects dangerous command dd" {
  run bash -c '"$1" --pattern "Bash(dd *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json" 2>/dev/null) || count=0
  [[ "$count" -eq 0 ]]
}

@test "learn: rejects pattern with path traversal" {
  run bash -c '"$1" --pattern "Bash(cat ../etc/passwd *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json" 2>/dev/null) || count=0
  [[ "$count" -eq 0 ]]
}

@test "learn: rejects pattern with command substitution" {
  run bash -c '"$1" --pattern "Bash(echo \$(whoami) *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json" 2>/dev/null) || count=0
  [[ "$count" -eq 0 ]]
}

@test "learn: accepts safe command git" {
  run bash -c '"$1" --pattern "Bash(git status *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(git status *)" ]]
}

@test "learn: accepts safe command npm test" {
  run bash -c '"$1" --pattern "npm test" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR"
  local patterns
  patterns=$(jq -r '.permissions.allow[]' "$HOME/.claude/settings.local.json")
  [[ "$patterns" == "Bash(npm test *)" ]]
}

# -- concurrent access --

@test "learn: concurrent writes do not lose patterns" {
  # Fire two concurrent auto-learn invocations and verify both patterns survive
  bash -c '"$1" --pattern "Bash(ls *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR" &
  bash -c '"$1" --pattern "Bash(git *)" --scope global --root "$2"' \
    _ "$LEARN_SCRIPT" "$TEST_DIR" &
  wait

  local count
  count=$(jq '.permissions.allow | length' "$HOME/.claude/settings.local.json")
  [[ "$count" -eq 2 ]]
}
