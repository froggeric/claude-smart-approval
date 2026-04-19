# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Claude Code PreToolUse hook that auto-approves safe bash commands. Parses compound commands (pipes, chains, subshells) into sub-commands and checks each against allow/deny lists. Falls back to AI evaluation via `claude -p` for unknown commands.

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

# Debug a full hook decision
echo '{"tool_input":{"command":"ls | grep foo"}}' | ./auto-approve.sh --debug
```

## Architecture

Three-script pipeline invoked as a Claude Code hook:

1. **`auto-approve.sh`** — Entry point. Stage 1: loads permissions from settings files, parses compound commands via shfmt AST, checks each sub-command against allow/deny lists. Stage 2: dispatches to smart-approve.sh for unknown commands.

2. **`smart-approve.sh`** — AI evaluation. Builds a security classification prompt, calls `claude -p --model haiku`, parses the JSON response into allow/deny/ask decisions. Includes prompt injection sanitization.

3. **`auto-learn.sh`** — Pattern persistence. Normalizes approved patterns into `Bash(cmd *)` format, validates they aren't dangerous, deduplicates across settings layers, writes to the correct file with mutex locking.

Supporting files:
- `eval-prompt.sh` — Prompt evaluation harness for testing prompt templates
- `prompts/` — Candidate prompt templates
- `test/prompt-eval-suite.json` — 45 test cases across 7 categories for prompt scoring
- `hooks/hooks.json` — Plugin hook registration
- `.claude-plugin/plugin.json` — Plugin metadata

## Testing

191 BATS tests in `test/`. Test helpers in `test/test_helper.bash`:

- `run_parse "cmd"` — test command extraction (parse mode)
- `run_hook "cmd" '["Bash(ls *)"]'` — test Stage 1 allow/deny with `SMART_APPROVE_ENABLED=false`
- `run_hook_smart "cmd" '[]' '[]' "$mock_response"` — test Stage 2 with mocked `claude -p`
- `create_mock_claude` — creates a temp script that returns `$MOCK_RESPONSE`, cleaned up automatically

Stage 1 tests disable smart approval via `SMART_APPROVE_ENABLED=false` and Stage 1 logging via `AUTO_APPROVE_LOG_FILE=""`. Stage 2 tests use `CLAUDE_CMD` to point at a mock and `SMART_APPROVE_AUTO_LEARN=false` to skip file writes.

Environment variables for logging:
- `AUTO_APPROVE_LOG_FILE` — Stage 1 log path (default: `~/.claude/auto-approve.log`, set empty to disable)
- `AUTO_APPROVE_LOG_MAX_LINES` — Stage 1 rotation limit (default: `1000`)
- `SMART_APPROVE_LOG_FILE` — Stage 2 log path (default: `~/.claude/smart-approval.log`, set empty to disable)
- `SMART_APPROVE_LOG_MAX_LINES` — Stage 2 rotation limit (default: `500`)

## Settings Layers

Permissions loaded from (in order): `~/.claude/settings.json`, `~/.claude/settings.local.json`, `<git-root>/.claude/settings.json`, `<git-root>/.claude/settings.local.json`. Auto-learn writes to the local variant (`*.local.json`) to avoid polluting synced settings.

## Log review

Log format: JSONL with fields `ts`, `cmd`, `decision`, `reason`, `pattern`, `scope`. Test artifacts have empty `cmd` or canned vectors (`rm -rf /`, `curl https://example.com`, `rm -rf /tmp/test`, `ls; unknown_cmd`, `git status`).

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

bash 3.2+ (main scripts), shfmt (AST parsing), jq (JSON + AST walking), claude CLI (AI evaluation, optional). CI uses `mfinelli/setup-shfmt@v2` and `apt-get install jq bats`.
