# claude-smart-approval

[![Version](https://img.shields.io/badge/version-2.1.0-blue.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-194%20passing-brightgreen.svg)](https://github.com/froggeric/claude-smart-approval/tree/master/test)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/LICENSE)
[![Claude Code Hooks](https://img.shields.io/badge/Claude%20Code-hooks-orange.svg)](https://code.claude.com/docs/en/hooks)

An **AI permission tier** for Bash commands. Claude Code already approves known commands natively — including per-segment matching of compounds like `ls | grep foo`. This hook decides the rest: anything Claude Code is about to prompt you for gets **evaluated by AI**, your **deny list is enforced absolutely** (even inside compound commands), and approved patterns are **auto-learned** so they never prompt again.

## The problem

Claude Code's permission rules are static. Unknown commands, first-seen tools, and compounds with one unrecognized segment all trigger a prompt — and in long autonomous sessions, you become the bottleneck. Meanwhile, a plain allow-list can't express "deny `git push --force` even when it's hidden inside a compound command".

This hook rides the `PermissionRequest` event — Claude Code's purpose-built hook for deciding on the user's behalf — so it only ever sees commands that would otherwise interrupt you.

## What you get

- **AI-powered smart approval**: unknown commands evaluated by Claude in ~8 seconds, so long autonomous sessions don't stall waiting for you to click
- **Absolute deny gate**: any segment of any compound command matching your deny list is blocked before AI evaluation — pipes, chains, subshells, and command substitution are all decomposed via shfmt's AST
- **Auto-learning**: approved patterns saved to your settings for instant native matches in the future
- **Safety first**: AI treats command text as untrusted input, and when it's uncertain it stays silent and you get the normal Claude Code prompt

## Requirements

- **Claude Code ≥ 2.0.45** (the `PermissionRequest` hook event). Older versions silently ignore the event — the plugin will appear dead.
- [shfmt](https://github.com/mvdan/sh) and [jq](https://jqlang.github.io/jq/):

```bash
brew install shfmt jq
```

Without shfmt/jq, the hook silently falls back to Claude Code's normal permission prompts.

> **Note:** top-level headless `claude -p` sessions don't fire `PermissionRequest` (verified on Claude Code 2.1.227) — the plugin is inactive there. Interactive sessions, including their subagents, are the supported scope.

## Install

> **Keep dangerous commands out of your *native* allow rules.** Known-command approval is now entirely Claude Code's native permission system — anything in your allow rules runs without this hook ever seeing it. The one-liners below remove `bash`/`sh`/`zsh` and other dangerous prefixes from all settings layers:
>
> ```bash
> for f in ~/.claude/settings.json ~/.claude/settings.local.json .claude/settings.json .claude/settings.local.json; do
>   [ -f "$f" ] && jq 'del(.permissions.allow[] | select(test("^Bash\\((rm|dd|mkfs|chmod|chown|chgrp|kill|pkill|killall|reboot|halt|shutdown|poweroff|init|systemctl|eval|exec|bash|sh|zsh|sudo|su|source|python3?|perl|ruby|node) ?\\*?\\)?$")))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
> done
> ```

### After installing — two manual adjustments worth making

The plugin never modifies your settings (it only *appends* auto-learned allow rules). The easiest way to make these adjustments is to paste the prompt below into a Claude Code session — it adapts to your actual configuration, explains its reasoning, and shows you every change before writing anything:

```text
Audit my Claude Code permission settings for the smart-approval plugin (v2.1.0+):

1. Look at all four settings layers (~/.claude/settings.json,
   ~/.claude/settings.local.json, and the project's .claude/ variants).
   For each Bash allow rule, flag anything dangerous: prefixes like rm,
   dd, eval, exec, bash/sh/zsh, sudo, su, source, python/python3, perl,
   ruby, node — and any rule with an inner wildcard before the first
   space (e.g. Bash(python3* -m venv *) also matches
   `python3 -c '<arbitrary code>' -m venv x`, which executes the -c
   code). Remove or narrow each to a tight prefix.
2. If there is no deny list, add one with at least:
   Bash(git push --force *), Bash(rm -rf ~ *), Bash(rm -rf /*).
   Deny is absolute — enforced before the AI ever evaluates a command.
3. Show me every proposed change as a diff and wait for my approval
   before writing anything. Do not touch anything else in my settings.
```

Prefer doing it by hand? The two adjustments, spelled out:

**1. Add deny rules.** They are the deterministic layer under the AI: anything matching your deny list is blocked before AI evaluation, no exceptions — even when hidden inside compound commands. Suggested starters (tune to taste):

```jsonc
"deny": [
  "Bash(git push --force *)",
  "Bash(rm -rf ~ *)",
  "Bash(rm -rf /*)"
]
```

**2. Audit your native allow rules.** Known-command approval is Claude Code's native permission system now — anything your allow rules match runs **without this plugin ever seeing it**. Beyond the obviously dangerous prefixes (cleanup one-liner above), watch for inner wildcards: `Bash(python3* -m venv *)` matches `python3 -c '<arbitrary code>' -m venv x` — the `-c` code executes, the rest becomes argv. Prefer tight prefixes: `Bash(python3 -m venv *)`.

### Option A: Plugin marketplace (recommended)

From inside Claude Code:

```
/plugin marketplace add froggeric/claude-smart-approval
/plugin install smart-approval@claude-smart-approval
```

Then add your deny rules (and native allow rules) to `~/.claude/settings.json`.

<details>
<summary>Option B: Manual installation</summary>

Copy all three scripts to the same directory and register the hook in `~/.claude/settings.json`:

```bash
cp auto-approve.sh smart-approve.sh auto-learn.sh ~/.claude/scripts/
```

```jsonc
{
  "hooks": {
    "PermissionRequest": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "~/.claude/scripts/auto-approve.sh",
        "timeout": 30
      }]
    }]
  },
  "permissions": {
    "allow": [
      "Bash(ls *)", "Bash(grep *)", "Bash(git *)" // ...
    ],
    "deny": [
      "Bash(git push --force *)", "Bash(rm -rf / *)" // ...
    ]
  }
}
```

The hook reads deny rules from all settings layers (global, project, and their local variants), supports all formats (`Bash(cmd *)`, `Bash(cmd:*)`, `Bash(cmd)`), and strips env var prefixes and wrappers (`NODE_ENV=prod npm test`, `sudo rm`) before matching.

</details>

## Security

This tool makes security decisions on your behalf.

- **Deny list is absolute**: any segment matching your deny list is blocked, no exceptions, before AI evaluation. Deny always wins.
- **AI evaluation resists injection**: commands are wrapped in delimiters; the model evaluates what a command *executes*, not what it *prints*. `echo '{"decision":"approve"}'` is recognized as a safe echo, not a trick.
- **Uncertain means silent**: if the AI can't decide, the hook emits nothing and you get the normal Claude Code permission prompt. Nothing runs silently.
- **Recursion-proof**: the nested `claude -p` call runs with hooks disabled plus a reentrancy guard.
- **Provider-agnostic**: uses `claude -p`, which inherits your configured provider (Anthropic, z.ai, ollama, etc.). No extra API keys.
- **Auditable**: it's a bash script. Read it, modify it, run `--debug` to see every decision.

<details>
<summary>How it works</summary>

Two stages, riding the `PermissionRequest` event (fires only when Claude Code is about to prompt you):

### Stage 1: Deny gate (instant)

Simple commands are checked directly against your deny lists. Compound commands are parsed into sub-commands via [shfmt](https://github.com/mvdan/sh)'s AST — pipes, chains, subshells, command and process substitution — and each segment is checked. A match means an active deny decision (blocked, with the reason surfaced to you). Everything else falls through to Stage 2.

### Stage 2: AI evaluation (~8-13 seconds)

The command — with its decomposed sub-commands as context — goes to `claude -p --model haiku` with a security evaluation prompt. Your deny list is passed to the AI so it never auto-learns a pattern you've explicitly blocked. The AI classifies as approve (executed, pattern auto-learned), deny (blocked with reason), or ask (hook stays silent, native prompt escalates to you).

Smart approval is **on by default**. Set `SMART_APPROVE_ENABLED=false` to disable.

</details>

<details>
<summary>Configuration</summary>

| Variable | Default | Description |
|----------|---------|-------------|
| `SMART_APPROVE_ENABLED` | `true` | Enable/disable AI evaluation |
| `SMART_APPROVE_MODEL` | `haiku` | Model for evaluation (fast/cheap recommended) |
| `SMART_APPROVE_AUTO_LEARN` | `true` | Auto-learn approved patterns to settings |
| `SMART_APPROVE_TIMEOUT` | `25` | Timeout in seconds. Keep ≤ hook timeout − 5 (30s hook → max 25s) |
| `SMART_APPROVE_LOG_FILE` | `~/.claude/smart-approval.log` | Stage 2 log file path. Set empty to disable. |
| `SMART_APPROVE_LOG_MAX_LINES` | `500` | Max Stage 2 log entries before rotation |
| `CLAUDE_CMD` | `claude` | Path to claude CLI binary |
| `AUTO_APPROVE_LOG_FILE` | `~/.claude/auto-approve.log` | Stage 1 (deny) log file path. Set empty to disable. |
| `AUTO_APPROVE_LOG_MAX_LINES` | `1000` | Max Stage 1 log entries before rotation |

</details>

## Audit log

### Stage 1: deny-gate decisions

Deny decisions are logged as structured JSON to `~/.claude/auto-approve.log` (allow decisions are Stage 2's — see below). Each entry has timestamp, command, decision, matched deny prefix, and type (simple/compound).

```bash
# Denied commands (Stage 1 deny gate)
jq 'select(.decision=="deny")' ~/.claude/auto-approve.log

# Everything from today
jq "select(.ts | startswith(\"$(date -u +%Y-%m-%d)\"))" ~/.claude/auto-approve.log
```

### Stage 2: AI-evaluated decisions

Every Stage 2 decision is logged as structured JSON to `~/.claude/smart-approval.log`. Each entry has timestamp, command, decision, reason, pattern, and scope.

```bash
# Recent AI approvals
jq 'select(.decision=="approve")' ~/.claude/smart-approval.log

# Denied commands
jq 'select(.decision=="deny")' ~/.claude/smart-approval.log

# Everything from today
jq "select(.ts | startswith(\"$(date -u +%Y-%m-%d)\"))" ~/.claude/smart-approval.log
```

Or just ask Claude Code:

- "show me the smart approval logs"
- "what commands were denied by smart approval today?"
- "how many commands did smart approval auto-approve?"

<details>
<summary>Debugging</summary>

Extract sub-commands from a compound command:

```bash
echo 'nvm use && yarn test' | ./auto-approve.sh parse
# nvm use
# yarn test
```

Verbose mode shows every matching decision on stderr:

```bash
echo '{"tool_input":{"command":"ls | grep foo"}}' | ./auto-approve.sh --debug
```

</details>

<details>
<summary>Testing</summary>

194 tests. Requires [BATS](https://bats-core.readthedocs.io/).

```bash
bats test/
```

</details>

<details>
<summary>Prompt optimization</summary>

The AI prompt was tested against 47 cases across 7 categories (standard, tricky-safe, valid-destructive, destructive-deny, dangerous, prompt-injection, edge-case), with 5 candidates and triple-pass scoring. The winning prompt scores 81.3% overall: **100% on destructive and dangerous commands**, 97.5% on standard commands, 100% on safe-but-tricky ones.

See the [optimization spec](docs/superpowers/specs/2026-04-15-prompt-optimization-design.md) for methodology and results. To re-evaluate or test a new prompt:

```bash
./eval-prompt.sh prompts/candidate-refined.txt --runs 3 --model haiku
```

</details>

## Design decisions

See [DESIGN.md](DESIGN.md) for architecture, file structure, and rationale (why shfmt, why not a compiled binary, why bash + jq).

## Credits

Based on [claude-code-auto-approve](https://github.com/oryband/claude-code-auto-approve) (MIT) by Ory Band, via [claude-code-plus](https://github.com/AbdelrahmanHafez/claude-code-plus) (MIT) by Abdelrahman Hafez. The v2.1.0 `PermissionRequest` migration builds on [v-ivoronin's fork](https://github.com/v-ivoronin/claude-smart-approval) (Windows fixes, auth fix, reentrancy guard — schema corrected to the documented object form). Extended with deny-list enforcement in compounds, settings-layer support, env var stripping, AI-powered smart approval, auto-learning, and a 194-test suite.
