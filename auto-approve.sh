#!/usr/bin/env bash
# shellcheck shell=bash
# auto-approve — PermissionRequest hook for Claude Code
#
# AI permission tier for Bash commands Claude Code is about to prompt for.
# Parses compound commands (pipes, chains, subshells) into sub-commands,
# actively denies anything matching your deny list, and evaluates the rest
# via smart-approve.sh (claude -p). Emits a PermissionRequest decision
# object on allow/deny; emits nothing to fall through to the native prompt.
#
# See README.md for full documentation.
#
# Dependencies: bash 3.2+, shfmt, jq

set -uo pipefail

# Reentrancy guard. The AI tier shells out to `claude -p`, a nested Claude Code
# session. If that session ever loads hooks, this script re-enters and recurses.
# smart-approve.sh exports SMART_APPROVE_ACTIVE into the child's environment
# (the `--settings '{"disableAllHooks":true}'` flag is the primary guard).
# Exit 0 with no output means "no decision" — normal flow applies.
if [[ -n "${SMART_APPROVE_ACTIVE:-}" ]]; then exit 0; fi
export SMART_APPROVE_ACTIVE=1

DEBUG=false

deny() {
  jq -cn --arg msg "$1" '{
    hookSpecificOutput: {hookEventName:"PermissionRequest", decision:{behavior:"deny", message:$msg}},
    systemMessage: $msg
  }'
  # PermissionRequest ignores exit codes — the decision object on stdout is
  # the only way to deny, and the script must exit 0 for that JSON to be honored.
  exit 0
}

# Stage 1 decision logging (deny decisions only — allows come from Stage 2
# and are logged by smart-approve.sh)
AUTO_APPROVE_LOG_FILE="${AUTO_APPROVE_LOG_FILE:-$HOME/.claude/auto-approve.log}"
AUTO_APPROVE_LOG_MAX_LINES="${AUTO_APPROVE_LOG_MAX_LINES:-1000}"

debug() { if $DEBUG; then printf '[approve-compound] %s\n' "$*" >&2; fi; }

# shellcheck disable=SC2034
_MATCHED_PREFIX=""

log_stage1_decision() {
  [[ -n "${AUTO_APPROVE_LOG_FILE:-}" ]] || return 0
  local command="$1" decision="$2" matched_prefix="${3:-}" cmd_type="${4:-}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

  # Append structured JSON line; graceful failure if path doesn't exist
  jq -cn \
    --arg ts "$ts" \
    --arg cmd "$command" \
    --arg dec "$decision" \
    --arg prefix "$matched_prefix" \
    --arg ctype "$cmd_type" \
    '{ts:$ts, cmd:$cmd, decision:$dec, matched_prefix:$prefix, type:$ctype}' \
    >> "$AUTO_APPROVE_LOG_FILE" 2>/dev/null || return 0

  # Rotate if over limit
  local line_count
  line_count=$(wc -l < "$AUTO_APPROVE_LOG_FILE" 2>/dev/null | tr -d ' ')
  if [[ "$line_count" -gt "${AUTO_APPROVE_LOG_MAX_LINES}" ]]; then
    local tmp
    tmp=$(mktemp) && tail -n "${AUTO_APPROVE_LOG_MAX_LINES}" "$AUTO_APPROVE_LOG_FILE" > "$tmp" && mv "$tmp" "$AUTO_APPROVE_LOG_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Deny-list loading (single pass over all settings files)
# ---------------------------------------------------------------------------

find_git_root() {
  local toplevel git_dir git_common_dir
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || return
  git_dir=$(git rev-parse --git-dir 2>/dev/null)
  git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ "$git_dir" != "$git_common_dir" ]]; then
    dirname "$git_common_dir"
  else
    printf '%s\n' "$toplevel"
  fi
}

# Populates the caller's denied_prefixes array from the deny lists of all
# settings layers. Allow lists are intentionally not read: natively allowed
# commands never prompt, so the hook never sees them.
load_prefixes() {
  local git_root
  git_root=$(find_git_root 2>/dev/null || true)

  local files=(
    "$HOME/.claude/settings.json"
    "$HOME/.claude/settings.local.json"
  )
  if [[ -n "$git_root" ]]; then
    files+=("$git_root/.claude/settings.json" "$git_root/.claude/settings.local.json")
  else
    files+=(".claude/settings.json" ".claude/settings.local.json")
  fi

  local line
  while IFS= read -r line; do
    # Native Windows jq (WinGet/choco) writes CRLF; `read -r` keeps the \r, which
    # would make every prefix unmatchable. Harmless no-op where jq emits LF.
    line="${line%$'\r'}"
    case "$line" in
      deny:*) denied_prefixes+=("${line#deny:}") ;;
    esac
  done < <(
    for file in "${files[@]}"; do
      [[ -f "$file" ]] || continue
      debug "Reading deny prefixes from: $file"
      jq -r '
        def extract_prefix: sub("^Bash\\("; "") | sub("( \\*|\\*|:\\*)\\)$"; "") | sub("\\)$"; "");
        (.permissions.deny[]? // empty | select(startswith("Bash(")) | "deny:" + extract_prefix)
      ' "$file" 2>/dev/null || true
    done | sort -u
  )
}

# ---------------------------------------------------------------------------
# Command detection and parsing (shfmt AST -> individual commands via jq)
# ---------------------------------------------------------------------------

# Returns 0 if the command needs compound parsing (contains shell metacharacters
# that could hide sub-commands: pipes, chains, semicolons, command substitution,
# process substitution, backticks).
needs_compound_parse() {
  # shellcheck disable=SC2016  # $( is a literal pattern, not an expansion
  [[ "$1" == *['|&;`'$'\n']* || "$1" == *'$('* || "$1" == *'<('* || "$1" == *'>('* ]]
}

# read returns 1 on EOF before delimiter; || true prevents exit under pipefail
read -r -d '' SHFMT_AST_FILTER << 'JQEOF' || true
def get_part_value:
  if (type == "object" | not) then ""
  elif .Type == "Lit" then .Value // ""
  elif .Type == "DblQuoted" then
    "\"" + ([.Parts[]? | get_part_value] | join("")) + "\""
  elif .Type == "SglQuoted" then
    "'" + (.Value // "") + "'"
  elif .Type == "ParamExp" then
    "$" + (.Param.Value // "")
  elif .Type == "CmdSubst" then "$(..)"
  else ""
  end;

def find_cmd_substs:
  if type == "object" then
    if .Type == "CmdSubst" or .Type == "ProcSubst" then .
    elif .Type == "DblQuoted" then .Parts[]? | find_cmd_substs
    elif .Type == "ParamExp" then
      (.Exp?.Word | find_cmd_substs),
      (.Repl?.Orig | find_cmd_substs),
      (.Repl?.With | find_cmd_substs)
    elif .Parts then .Parts[]? | find_cmd_substs
    else empty
    end
  elif type == "array" then .[] | find_cmd_substs
  else empty
  end;

def get_arg_value:
  [.Parts[]? | get_part_value] | join("");

def get_command_string:
  if .Type == "CallExpr" and .Args then
    [.Args[] | get_arg_value] | map(select(length > 0)) | join(" ")
  else empty
  end;

def extract_commands:
  if type == "object" then
    if .Type == "CallExpr" then
      get_command_string,
      (.Args[]? | find_cmd_substs | .Stmts[]? | extract_commands),
      (.Assigns[]?.Value | find_cmd_substs | .Stmts[]? | extract_commands),
      (.Assigns[]?.Array?.Elems[]?.Value | find_cmd_substs | .Stmts[]? | extract_commands),
      (.Redirs[]?.Word | find_cmd_substs | .Stmts[]? | extract_commands)
    elif .Type == "BinaryCmd" then
      (.X | extract_commands), (.Y | extract_commands)
    elif .Type == "Subshell" or .Type == "Block" then
      (.Stmts[]? | extract_commands)
    elif .Type == "CmdSubst" then
      (.Stmts[]? | extract_commands)
    elif .Type == "IfClause" then
      (.Cond[]? | extract_commands),
      (.Then[]? | extract_commands),
      (.Else | extract_commands)
    elif .Type == "WhileClause" or .Type == "UntilClause" then
      (.Cond[]? | extract_commands), (.Do[]? | extract_commands)
    elif .Type == "ForClause" then
      (.Loop.Items[]? | find_cmd_substs | .Stmts[]? | extract_commands),
      (.Do[]? | extract_commands)
    elif .Type == "CaseClause" then
      (.Items[]?.Stmts[]? | extract_commands)
    elif .Type == "DeclClause" then
      (.Args[]?.Value | find_cmd_substs | .Stmts[]? | extract_commands),
      (.Args[]?.Array?.Elems[]?.Value | find_cmd_substs | .Stmts[]? | extract_commands)
    elif .Cmd then
      (.Cmd | extract_commands),
      (.Redirs[]?.Word | find_cmd_substs | .Stmts[]? | extract_commands)
    elif .Stmts then
      (.Stmts[] | extract_commands)
    else
      (.[] | extract_commands)
    end
  elif type == "array" then
    (.[] | extract_commands)
  else empty
  end;

extract_commands | select(length > 0)
JQEOF
readonly SHFMT_AST_FILTER

# Parse compound command into individual commands (NUL-delimited)
parse_compound() {
  local cmd="$1"

  # Normalize [[ \! $x =~ ]] patterns that shfmt can't parse
  if [[ "$cmd" == *"=~"* ]]; then
    cmd=$(sed -E 's/\[\[[[:space:]]*\\?![[:space:]]+(.+)[[:space:]]+=~/! [[ \1 =~/g' <<< "$cmd")
  fi

  local ast
  if ! ast=$(shfmt -ln bash -tojson <<< "$cmd" 2>/dev/null); then
    debug "shfmt parse failed"
    return 1
  fi

  local raw_commands
  raw_commands=$(jq -r "$SHFMT_AST_FILTER" <<< "$ast" 2>/dev/null) || return 1

  while IFS= read -r line; do
    line="${line%$'\r'}"   # strip CR from native Windows jq output
    [[ -z "$line" ]] && continue
    # Recursively expand bash -c / sh -c
    if [[ "$line" =~ ^(env[[:space:]]+)?(/[^[:space:]]*/)?((ba)?sh)[[:space:]]+-c[[:space:]]*[\'\"](.*)[\'\"]$ ]]; then
      debug "Recursing into shell -c: ${BASH_REMATCH[5]}"
      if ! parse_compound "${BASH_REMATCH[5]}"; then
        # Inner parse failed — emit wrapper as-is so it gets checked
        # against the deny list (and likely falls through)
        printf '%s\0' "$line"
      fi
    else
      printf '%s\0' "$line"
    fi
  done <<< "$raw_commands"
}

# ---------------------------------------------------------------------------
# Deny-list matching
# ---------------------------------------------------------------------------

# Strip leading env var assignments (VAR=val cmd ...).
# Populates _STRIP_CANDIDATES global with original and stripped forms.
_STRIP_CANDIDATES=()
strip_env_vars() {
  local full_command="$1"
  local stripped="$full_command"

  while [[ "$stripped" =~ ^[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|\'[^\']*\'|[^[:space:]]*)[[:space:]]+(.*) ]]; do
    stripped="${BASH_REMATCH[2]}"
  done

  _STRIP_CANDIDATES=("$full_command")
  [[ "$stripped" != "$full_command" ]] && _STRIP_CANDIDATES+=("$stripped")

  # Strip wrapper commands (env, sudo, etc.)
  local wrapper_cmds="env exec nice nohup timeout sudo su xargs chroot strace ltrace unshare"
  local w
  while true; do
    local first="${stripped%%[[:space:]]*}"
    local found=false
    for w in $wrapper_cmds; do
      if [[ "$first" == "$w" ]]; then
        stripped="${stripped#"$w"}"
        stripped="${stripped#"${stripped%%[![:space:]]*}"}"
        found=true
        break
      fi
    done
    $found || break
  done
  [[ "$stripped" != "$full_command" && "$stripped" != "${_STRIP_CANDIDATES[${#_STRIP_CANDIDATES[@]}-1]}" ]] && _STRIP_CANDIDATES+=("$stripped")
}

# Check if a command matches any prefix. Prefixes passed as positional args.
matches_prefix_list() {
  local full_command="$1"
  local label="${2:-}"
  shift 2

  [[ $# -eq 0 ]] && return 1

  strip_env_vars "$full_command"

  local cmd prefix
  for cmd in "${_STRIP_CANDIDATES[@]}"; do
    for prefix in "$@"; do
      if [[ "$cmd" == "$prefix" ]] || [[ "$cmd" == "$prefix "* ]] || [[ "$cmd" == "$prefix/"* ]]; then
        debug "MATCH ($label): '$cmd' -> '$prefix'"
        _MATCHED_PREFIX="$prefix"
        return 0
      fi
    done
  done
  return 1
}

# Check if any command (passed as args) matches the deny list.
any_denied() {
  [[ ${#denied_prefixes[@]} -eq 0 ]] && return 1

  local cmd
  for cmd in "$@"; do
    [[ -z "$cmd" ]] && continue
    if matches_prefix_list "$cmd" "deny" ${denied_prefixes[@]+"${denied_prefixes[@]}"}; then
      debug "Denied segment found: $cmd"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Stage 2: Smart approval via AI evaluation (smart-approve.sh + auto-learn.sh)
# ---------------------------------------------------------------------------

# Evaluate a command via AI. On success, outputs hook JSON and exits.
# On failure (or disabled), returns 1 so the caller can fall through.
# NOTE: This function exits the script on allow/deny decisions — same
# pattern as deny() above.
run_smart_approve() {
  local command="$1"
  local cwd="$2"
  shift 2

  [[ "${SMART_APPROVE_ENABLED:-true}" != "true" ]] && return 1

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local smart_output
  if [[ "${#denied_prefixes[@]}" -gt 0 ]]; then
    smart_output=$(
      { printf '%s\n' "$@"; echo "---DENY_LIST---"; printf '%s\n' ${denied_prefixes[@]+"${denied_prefixes[@]}"}; } | \
        "$script_dir/smart-approve.sh" \
          --command "$command" \
          --cwd "$cwd" 2>/dev/null
    ) || true
  else
    smart_output=$(printf '%s\n' "$@" | \
      "$script_dir/smart-approve.sh" \
        --command "$command" \
        --cwd "$cwd" 2>/dev/null) || true
  fi

  [[ -z "$smart_output" ]] && return 1

  # Parse output once into an array (avoid 4 separate pipelines)
  local -a output_lines=()
  while IFS= read -r line; do
    output_lines+=("${line%$'\r'}")   # strip CR from native Windows jq output
  done <<< "$smart_output"

  local first_line="${output_lines[0]}"

  if [[ "$first_line" == *'"behavior":"allow"'* ]]; then
    printf '%s\n' "$first_line"

    # Auto-learn the pattern (if enabled)
    if [[ "${SMART_APPROVE_AUTO_LEARN:-true}" == "true" ]]; then
      local pattern="" scope=""
      for line in "${output_lines[@]:1}"; do
        case "$line" in
          AUTO_LEARN_PATTERN=*) pattern="${line#AUTO_LEARN_PATTERN=}" ;;
          AUTO_LEARN_SCOPE=*) scope="${line#AUTO_LEARN_SCOPE=}" ;;
        esac
      done
      if [[ -n "$pattern" ]]; then
        local git_root
        git_root=$(find_git_root 2>/dev/null || true)
        "$script_dir/auto-learn.sh" \
          --pattern "$pattern" \
          --scope "${scope:-project}" \
          --root "$git_root" &>/dev/null || true
      fi
    fi
    exit 0
  elif [[ "$first_line" == *'"behavior":"deny"'* ]]; then
    # STDOUT + exit 0 — PermissionRequest only honors the stdout decision
    # object; stderr output would be silently discarded.
    printf '%s\n' "$first_line"
    exit 0
  fi

  # Ask or unparseable: no decision — fall through to the native prompt.
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local deny_json="" mode="hook" cwd=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debug) DEBUG=true; shift ;;
      --deny) deny_json="$2"; shift 2 ;;
      parse) mode="parse"; shift ;;
      *) shift ;;
    esac
  done

  # Guard: dependencies
  for dep in jq shfmt; do
    if ! command -v "$dep" &>/dev/null; then
      debug "Missing $dep, falling through"
      exit 0
    fi
  done

  # Parse mode: extract commands from stdin (plain text), one per line
  if [[ "$mode" == "parse" ]]; then
    local cmd
    cmd=$(cat)
    [[ -z "$cmd" ]] && exit 0
    if ! needs_compound_parse "$cmd"; then
      printf '%s\n' "$cmd"
    else
      local -a cmds=()
      while IFS= read -r -d '' c; do cmds+=("$c"); done < <(parse_compound "$cmd")
      for c in "${cmds[@]}"; do
        [[ -n "$c" ]] && printf '%s\n' "$c"
      done
    fi
    exit 0
  fi

  # Guard: read hook input
  local input command
  input=$(cat)
  command=$(jq -r '.tool_input.command // empty' <<< "$input" 2>/dev/null)
  [[ -z "$command" ]] && exit 0
  command="${command%$'\r'}"   # strip CR from native Windows jq output

  debug "Command: $command"

  # Load deny list (from settings, or from --deny for testing; the flag's
  # presence — even with an empty array — suppresses settings-file loading)
  local -a denied_prefixes=()
  if [[ -n "$deny_json" ]]; then
    local line
    while IFS= read -r line; do
      line="${line%$'\r'}"   # strip CR from native Windows jq output
      [[ -n "$line" ]] && denied_prefixes+=("$line")
    done < <(jq -r '.[] | sub("^Bash\\("; "") | sub("( \\*|\\*|:\\*)\\)$"; "") | sub("\\)$"; "")' <<< "$deny_json" 2>/dev/null)
  else
    load_prefixes
  fi
  debug "Loaded ${#denied_prefixes[@]} deny prefixes"

  # Simple command — deny-gate, then Stage 2
  if ! needs_compound_parse "$command"; then
    debug "Simple command"
    if any_denied "$command"; then
      log_stage1_decision "$command" "deny" "$_MATCHED_PREFIX" "simple"
      deny "Command matches deny list"
    fi
    # Stage 2: Smart approval for unknown simple commands
    cwd=$(jq -r '.cwd // empty' <<< "$input" 2>/dev/null)
    run_smart_approve "$command" "$cwd" "$command"
    exit 0
  fi

  # Compound command — parse into segments, deny-gate, then Stage 2
  debug "Compound command"
  local -a extracted_commands=()
  while IFS= read -r -d '' c; do extracted_commands+=("$c"); done < <(parse_compound "$command")

  # Parse failure or empty result — fall through to prompt (don't auto-approve
  # unparseable commands that may contain dangerous sub-commands)
  [[ ${#extracted_commands[@]} -eq 0 || -z "${extracted_commands[0]}" ]] && exit 0

  if any_denied "${extracted_commands[@]}"; then
    log_stage1_decision "$command" "deny" "$_MATCHED_PREFIX" "compound"
    deny "Compound command contains a denied sub-command"
  fi

  # Stage 2: Smart approval for unknown compound commands
  cwd=$(jq -r '.cwd // empty' <<< "$input")
  run_smart_approve "$command" "$cwd" "${extracted_commands[@]}"

  exit 0
}

main "$@"
