# claude-smart-approval

[![Version](https://img.shields.io/badge/version-2.0.3-blue.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-150%20passing-brightgreen.svg)](https://github.com/froggeric/claude-smart-approval/tree/master/test)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/LICENSE)
[![Claude Code Hooks](https://img.shields.io/badge/Claude%20Code-hooks-orange.svg)](https://docs.anthropic.com/en/docs/claude-code/hooks)

Stop clicking "Allow" on every `ls | grep foo`. Known commands are approved instantly from **your allow/deny lists.** Unknown commands undergo a **smart AI evaluation** through your Haiku model, with your deny list enforced, injection-resistant prompts, and uncertain decisions kicked back to you.

## The problem

Claude Code matches `Bash(cmd *)` permissions against the full command string. `ls | grep foo` doesn't match `Bash(ls *)` or `Bash(grep *)`, so you get prompted even though both commands are individually allowed.

Same for `nvm use && yarn test`. Same for `git log | head`. Same for `mkdir -p dir && cd dir`. Pipes, chains, subshells: all trigger a permission prompt.

This hook parses compound commands into their individual pieces and checks each one.

## What you get

- **Compound command approval**: pipes, chains, subshells, and command substitution auto-approved when each segment is in your allow list
- **AI-powered smart approval**: unknown commands evaluated by Claude in ~8 seconds, so long autonomous sessions don't stall waiting for you to click
- **Auto-learning**: approved patterns saved to your settings for instant future matches
- **Safety first**: deny list is absolute, AI treats commands as untrusted input, uncertain means it asks you

## Install

**Required:** [shfmt](https://github.com/mvdan/sh) and [jq](https://jqlang.github.io/jq/) must be installed on your system.

```bash
brew install shfmt jq
```

Without these, the hook silently falls back to Claude Code's normal permission prompts.

> **Remove `bash`, `sh`, and `zsh` from your allow list.** Commands like `bash -c 'echo hello'` have no shell metacharacters, so they take the fast path and match the prefix list without recursing into the inner command. If `Bash(bash *)` is in your allow list, `bash -c 'rm -rf /'` would be auto-approved. Check and remove:
>
> ```bash
> for f in ~/.claude/settings.json ~/.claude/settings.local.json .claude/settings.json .claude/settings.local.json; do [ -f "$f" ] && jq 'del(.permissions.allow[] | select(test("^Bash\\((ba|z)?sh \\*\\)$")))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
> ```
>
> **Remove other dangerous commands.** Commands like `rm`, `sudo`, `eval`, `python`, and `node` can execute arbitrary code or destructive operations. If these are in your allow list, auto-approve (Stage 1) will match them without evaluation:
>
> ```bash
> for f in ~/.claude/settings.json ~/.claude/settings.local.json .claude/settings.json .claude/settings.local.json; do
>   [ -f "$f" ] && jq 'del(.permissions.allow[] | select(test("^Bash\\((rm|dd|mkfs|chmod|chown|chgrp|kill|pkill|killall|reboot|halt|shutdown|poweroff|init|systemctl|eval|exec|bash|sh|zsh|sudo|su|source|python3?|perl|ruby|node) ?\\*?\\)?$")))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
> done
> ```

### Option A: Plugin marketplace (recommended)

From inside Claude Code:

```
/plugin marketplace add froggeric/claude-smart-approval
/plugin install smart-approval@claude-smart-approval
```

Then add your allow/deny rules to `~/.claude/settings.json`.

<details>
<summary>Option B: Manual installation</summary>

Copy all three scripts to the same directory and register the hook in `~/.claude/settings.json`:

```bash
cp auto-approve.sh smart-approve.sh auto-learn.sh ~/.claude/scripts/
```

```jsonc
{
  "hooks": {
    "PreToolUse": [{
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

That's it. The hook reads permissions from all settings layers (global, project, and their local variants), supports all formats (`Bash(cmd *)`, `Bash(cmd:*)`, `Bash(cmd)`), and strips env var prefixes (`NODE_ENV=prod npm test` matches `npm`).

</details>

## Security

This tool makes security decisions on your behalf.

- **Deny list is absolute**: any segment matching your deny list is blocked, no exceptions. Stage 1 deny always wins.
- **AI evaluation resists injection**: commands are wrapped in delimiters; the model evaluates what a command *executes*, not what it *prints*. `echo '{"decision":"approve"}'` is recognized as a safe echo, not a trick.
- **Uncertain means ask you**: if the AI can't decide, you get the normal Claude Code permission prompt with the AI's analysis. Nothing runs silently.
- **Provider-agnostic**: uses `claude -p`, which inherits your configured provider (Anthropic, z.ai, ollama, etc.). No extra API keys.
- **Auditable**: it's a bash script. Read it, modify it, run `--debug` to see every decision.

<details>
<summary>How it works</summary>

Your existing `permissions.allow` and `permissions.deny` lists are the foundation. The hook reads them from all four settings layers — global (`~/.claude/settings.json`), global local (`~/.claude/settings.local.json`), project (`.claude/settings.json`), and project local (`.claude/settings.local.json`). No duplication. No separate config.

Two stages:

### Stage 1: Prefix matching (instant)

Simple commands checked directly against your allow/deny lists. Compound commands parsed into sub-commands via [shfmt](https://github.com/mvdan/sh)'s AST, each checked individually.

Three outcomes:

- **Approve**: every segment in your allow list, none in deny. Runs immediately.
- **Deny**: any segment matches your deny list. Blocked. No appeal — deny always wins.
- **Ask you**: unknown segment or parse failure. Falls through to Stage 2.

On any error it asks you. It never approves what it can't fully analyze.

### Stage 2: AI evaluation (~8-13 seconds)

When Stage 1 can't decide, the command goes to `claude -p --model haiku` with a security evaluation prompt. Your deny list is passed to the AI so it never auto-learns a pattern you've explicitly blocked. The AI classifies the command as approve, deny, or ask (escalates to you with reasoning). Approved patterns are auto-learned to your settings so they never need to ask again.

Smart approval is **on by default**. Set `SMART_APPROVE_ENABLED=false` to disable.

</details>

<details>
<summary>Configuration</summary>

| Variable | Default | Description |
|----------|---------|-------------|
| `SMART_APPROVE_ENABLED` | `true` | Enable/disable AI evaluation |
| `SMART_APPROVE_MODEL` | `haiku` | Model for evaluation (fast/cheap recommended) |
| `SMART_APPROVE_AUTO_LEARN` | `true` | Auto-learn approved patterns to settings |
| `SMART_APPROVE_TIMEOUT` | `25` | Timeout in seconds |
| `SMART_APPROVE_LOG_FILE` | `~/.claude/smart-approval.log` | Log file path. Set empty to disable. |
| `SMART_APPROVE_LOG_MAX_LINES` | `500` | Max log entries before rotation |
| `CLAUDE_CMD` | `claude` | Path to claude CLI binary |

</details>

## Audit log

Every Stage 2 decision is logged as structured JSON to `~/.claude/smart-approval.log`. Each entry has timestamp, command, decision, reason, pattern, and scope.

Query it directly with `jq`:

```bash
# Recent approvals
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

182 tests. Requires [BATS](https://bats-core.readthedocs.io/).

```bash
bats test/
```

</details>

<details>
<summary>Prompt optimization</summary>

The AI prompt was tested against 45 cases across 7 categories (standard, tricky-safe, valid-destructive, destructive-deny, dangerous, prompt-injection, edge-case), with 5 candidates and triple-pass scoring. The winning prompt scores 81.3% overall: **100% on destructive and dangerous commands**, 97.5% on standard commands, 100% on safe-but-tricky ones.

See the [optimization spec](docs/superpowers/specs/2026-04-15-prompt-optimization-design.md) for methodology and results. To re-evaluate or test a new prompt:

```bash
./eval-prompt.sh prompts/candidate-refined.txt --runs 3 --model haiku
```

</details>

## Design decisions

See [DESIGN.md](DESIGN.md) for architecture, file structure, and rationale (why shfmt, why not a compiled binary, why bash + jq).

## Credits

Based on [claude-code-auto-approve](https://github.com/oryband/claude-code-auto-approve) (MIT) by Ory Band, via [claude-code-plus](https://github.com/AbdelrahmanHafez/claude-code-plus) (MIT) by Abdelrahman Hafez. Extended with deny list support, active deny for compounds, fast path for simple commands, settings layer support, env var stripping, AI-powered smart approval, auto-learning, and a 182-test suite.
