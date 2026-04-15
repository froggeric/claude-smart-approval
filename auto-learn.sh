#!/usr/bin/env bash
# shellcheck shell=bash
# auto-learn.sh — Auto-learning approved patterns to settings files
#
# Adds approved command patterns to the correct Claude Code settings layer.
# Global patterns (git, ls, make) go to ~/.claude/settings.local.json
# Project patterns (npm test, docker-compose) go to .claude/settings.local.json
#
# Dependencies: jq

set -uo pipefail

# Normalize a pattern into Bash(cmd *) format.
# Handles: "git status" → "Bash(git status *)"
#          "Bash(git status)" → "Bash(git status *)"
#          "Bash(git status *)" → "Bash(git status *)" (unchanged)
#          "ls" → "Bash(ls *)"
normalize_pattern() {
  local pattern="$1"
  [[ -z "$pattern" ]] && return 1

  # Strip Bash() wrapper if present
  pattern="${pattern#Bash(}"
  pattern="${pattern%)}"

  # Add * suffix if the pattern doesn't already end with *
  if [[ "$pattern" != *" *" ]]; then
    pattern="$pattern *"
  fi

  printf 'Bash(%s)' "$pattern"
}

# Validate that a normalized pattern is safe to write to settings.
# Rejects: dangerous commands, overly broad globs, path traversal, shell metacharacters.
validate_pattern() {
  local normalized="$1"
  [[ -z "$normalized" ]] && return 1

  # Extract the command prefix (inside Bash(...), before the first space-star)
  local inner="${normalized#Bash(}"
  inner="${inner%)}"
  local cmd_prefix="${inner%% *}"

  # Reject overly broad patterns (just a glob, no real command)
  if [[ "$cmd_prefix" == "*" || -z "$cmd_prefix" ]]; then
    return 1
  fi

  # Reject dangerous commands
  local -a dangerous_cmds=(rm dd mkfs chmod chown chgrp kill pkill killall
    reboot halt shutdown poweroff init systemctl)
  for dangerous in "${dangerous_cmds[@]}"; do
    if [[ "$cmd_prefix" == "$dangerous" ]]; then
      return 1
    fi
  done

  # Reject patterns containing path traversal or suspicious characters
  # Note: check only the inner content, not the Bash(...) wrapper which naturally contains ( )
  if [[ "$inner" =~ \.\./ || "$inner" =~ [\`\$] ]]; then
    return 1
  fi

  # Reject excessively long patterns
  [[ ${#normalized} -gt 100 ]] && return 1

  return 0
}

# Check if a pattern exists in any of the settings files for the given root
pattern_exists() {
  local pattern="$1"
  local home="$2"
  local project_root="$3"

  local files=(
    "$home/.claude/settings.json"
    "$home/.claude/settings.local.json"
  )
  if [[ -n "$project_root" ]]; then
    files+=("$project_root/.claude/settings.json" "$project_root/.claude/settings.local.json")
  fi

  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    if jq -e --arg p "$pattern" '.permissions.allow // [] | index($p)' "$file" &>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Acquire a mutex lock using mkdir (atomic on all POSIX filesystems).
# Usage: lock_acquire <lockdir> [timeout_seconds]
lock_acquire() {
  local lockdir="$1"
  local timeout="${2:-10}"
  local elapsed=0

  while ! mkdir "$lockdir" 2>/dev/null; do
    # Check for stale locks (older than 30 seconds)
    if [[ -d "$lockdir" ]]; then
      local lock_age
      lock_age=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0) ))
      if [[ "$lock_age" -gt 30 ]]; then
        rm -rf "$lockdir"
        continue
      fi
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
    if [[ "$elapsed" -ge $((timeout * 10)) ]]; then
      return 1
    fi
  done
  return 0
}

# Release a mutex lock acquired by lock_acquire.
lock_release() {
  rm -rf "$1" 2>/dev/null
}

# Add a pattern to the target settings file (atomic write with locking)
add_pattern() {
  local pattern="$1"
  local target_file="$2"

  # Ensure directory exists
  mkdir -p "$(dirname "$target_file")"

  # Use mkdir-based mutex for mutual exclusion to prevent TOCTOU races
  local lockdir="${target_file}.lockdir"
  lock_acquire "$lockdir" || return 1

  # Create file with minimal structure if it doesn't exist
  if [[ ! -f "$target_file" ]]; then
    echo '{"permissions":{"allow":[]}}' > "$target_file"
  fi

  # Atomic write via temp file in the same directory (same filesystem → atomic mv)
  local tmp
  tmp=$(mktemp "${target_file}.XXXXXX")
  if jq --arg p "$pattern" '
    .permissions.allow = (((.permissions.allow // []) + [$p]) | unique)
  ' "$target_file" > "$tmp"; then
    mv "$tmp" "$target_file"
  else
    rm -f "$tmp"
    lock_release "$lockdir"
    return 1
  fi

  lock_release "$lockdir"
}

main() {
  local pattern="" scope="project" project_root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pattern) pattern="$2"; shift 2 ;;
      --scope) scope="$2"; shift 2 ;;
      --root) project_root="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Validate
  [[ -z "$pattern" ]] && exit 0

  # Normalize pattern
  local normalized
  normalized=$(normalize_pattern "$pattern") || exit 0

  # Validate the pattern is safe to persist
  validate_pattern "$normalized" || exit 0

  # Skip if pattern already exists in any settings layer
  pattern_exists "$normalized" "$HOME" "$project_root" && exit 0

  # Determine target file
  local target_file
  case "$scope" in
    global)
      target_file="$HOME/.claude/settings.local.json"
      ;;
    *)
      if [[ -n "$project_root" ]]; then
        target_file="$project_root/.claude/settings.local.json"
      else
        # No project root — cannot safely determine where to write
        exit 0
      fi
      ;;
  esac

  add_pattern "$normalized" "$target_file"
}

main "$@"
