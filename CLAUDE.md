# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Claude Code PermissionRequest hook — an AI permission tier for Bash commands. Fires only when Claude Code is about to prompt the user (requires Claude Code ≥ 2.0.45; top-level headless `claude -p` sessions don't fire the event). Stage 1 parses compound commands (pipes, chains, subshells) via shfmt AST and denies anything matching the user's deny lists. Everything else falls through to Stage 2, which evaluates via `claude -p` and emits an allow/deny decision object — or nothing, which escalates to the native prompt.

## Commands

```bash
# Run all tests (requires bats, shfmt, jq)
bats test/

# Run a single test file
bats test/parsing.bats

# Lint shell scripts
shellcheck -x auto-approve.sh smart-approve.sh auto-learn.sh

# Evaluate a prompt template against the test suite
./eval-prompt.sh prompts/candidate-refined.txt --runs 3 --model haiku

# Debug a specific command's parsing
echo 'ls | grep foo' | ./auto-approve.sh parse

# Debug a full hook decision (deny gate + Stage 2 dispatch)
echo '{"tool_input":{"command":"ls | grep foo"}}' | ./auto-approve.sh --debug
```

## Architecture

Three-script pipeline invoked as a Claude Code hook:

1. **`auto-approve.sh`** — Entry point. Reentrancy-guarded (`SMART_APPROVE_ACTIVE`). Stage 1: loads deny rules from settings files, parses compound commands via shfmt AST, denies any matching segment (stdout decision object + exit 0 — PermissionRequest ignores exit codes). Stage 2: dispatches everything else to smart-approve.sh and relays its decision.

2. **`smart-approve.sh`** — AI evaluation. Builds a security classification prompt, calls `claude -p --model haiku --settings '{"disableAllHooks":true}'` (the old `--bare` flag skipped OAuth/keychain auth), parses the JSON response into allow/deny/silent decisions. Includes prompt injection sanitization. Silence (ask/failure) = native prompt.

3. **`auto-learn.sh`** — Pattern persistence. Normalizes approved patterns into `Bash(cmd *)` format, validates they aren't dangerous, deduplicates across settings layers, writes to the correct file with mutex locking.

Supporting files:
- `eval-prompt.sh` — Prompt evaluation harness for testing prompt templates
- `prompts/` — Candidate prompt templates
- `test/prompt-eval-suite.json` — 47 test cases across 7 categories for prompt scoring
- `hooks/hooks.json` — Plugin hook registration (PermissionRequest event)
- `.claude-plugin/plugin.json` — Plugin metadata

## Testing

194 BATS tests in `test/`. Test helpers in `test/test_helper.bash`:

- `run_parse "cmd"` — test command extraction (parse mode)
- `run_hook "cmd" '["Bash(rm *)"]'` — test Stage 1 deny gate; the second argument is the DENY list and is always passed (even `[]`) so real settings files are never read
- `run_hook_smart "cmd" '[]' "$mock_response"` — test Stage 2 with mocked `claude -p`
- `create_mock_claude` — creates a temp script that returns `$MOCK_RESPONSE`, cleaned up automatically

Stage 1 tests disable smart approval via `SMART_APPROVE_ENABLED=false`, the log via `AUTO_APPROVE_LOG_FILE=""`, and the reentrancy guard via `SMART_APPROVE_ACTIVE=` (empty — the guard checks non-empty). Stage 2 tests use `CLAUDE_CMD` to point at a mock and `SMART_APPROVE_AUTO_LEARN=false` to skip file writes.

Allow decisions only exist via Stage 2 (there is no allow fast path); `assert_fallthrough` requires exit 0 with completely empty stdout; `assert_denied` requires exit 0 plus the deny decision object on stdout.

Environment variables for logging:
- `AUTO_APPROVE_LOG_FILE` — Stage 1 deny log path (default: `~/.claude/auto-approve.log`, set empty to disable)
- `AUTO_APPROVE_LOG_MAX_LINES` — Stage 1 rotation limit (default: `1000`)
- `SMART_APPROVE_LOG_FILE` — Stage 2 log path (default: `~/.claude/smart-approval.log`, set empty to disable)
- `SMART_APPROVE_LOG_MAX_LINES` — Stage 2 rotation limit (default: `500`)

## Settings Layers

Deny rules (and Stage 2's auto-learned allow patterns) are read from (in order): `~/.claude/settings.json`, `~/.claude/settings.local.json`, `<git-root>/.claude/settings.json`, `<git-root>/.claude/settings.local.json`. Auto-learn writes to the local variant (`*.local.json`) to avoid polluting synced settings.

## Log review

Stage 1 log (`auto-approve.log`) is deny-only — JSONL with fields `ts`, `cmd`, `decision`, `matched_prefix`, `scope`-less `type` (simple/compound). Allow decisions are Stage 2's and live in `smart-approval.log` (`ts`, `cmd`, `decision` ∈ approve/deny/ask, `reason`, `pattern`, `scope`). Test artifacts have empty `cmd` or canned vectors (`rm -rf /`, `curl https://example.com`, `rm -rf /tmp/test`, `ls; unknown_cmd`, `git status`).

To clean test entries from the logs:
```bash
jq -c 'select(.cmd != "" and .cmd != "rm -rf /" and .cmd != "curl https://example.com" and .cmd != "rm -rf /tmp/test" and .cmd != "ls; unknown_cmd" and .cmd != "git status")' ~/.claude/smart-approval.log > /tmp/smart-approval-clean.json && mv /tmp/smart-approval-clean.json ~/.claude/smart-approval.log
```

The smart approval log accumulates test artifacts (empty `cmd` fields, repeated test vectors). Filter for real decisions:

```bash
# Remove entries with empty cmd
jq -c 'select(.cmd != "")' ~/.claude/smart-approval.log

# Exclude known test vectors
jq -c 'select(.cmd != "rm -rf /" and .cmd != "curl https://example.com" and .cmd != "rm -rf /tmp/test" and .cmd != "ls; unknown_cmd" and .cmd != "git status")' ~/.claude/smart-approval.log
```

Auto-learned patterns from before the C5 blocklist fix (v2.0.3) may still exist in settings files. Check all layers for dangerous commands on the blocklist:

```bash
for f in ~/.claude/settings.json ~/.claude/settings.local.json .claude/settings.json .claude/settings.local.json; do [ -f "$f" ] && echo "=== $f ===" && jq -r '.permissions.allow[]' "$f" | grep -iE '^Bash\((rm|dd|eval|exec|bash|sh|zsh|sudo|su|source|python|perl|ruby|node)\b' || true; done
```

## Dependencies

bash 3.2+ (main scripts), shfmt (AST parsing), jq (JSON + AST walking), claude CLI (AI evaluation, optional). CI uses `mfinelli/setup-shfmt@v2` and `apt-get install jq bats`. `.gitattributes` enforces LF line endings for shell scripts (Windows checkouts).
