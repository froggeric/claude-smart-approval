# claude-smart-approval

[![Version](https://img.shields.io/badge/version-2.1.0-blue.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-194%20passing-brightgreen.svg)](https://github.com/froggeric/claude-smart-approval/tree/master/test)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/LICENSE)
[![Claude Code Hooks](https://img.shields.io/badge/Claude%20Code-hooks-orange.svg)](https://code.claude.com/docs/en/hooks)

Claude Code asks before it runs a command it does not know. This plugin answers for you.

A small model reads the command. Safe ones run. Dangerous ones are blocked. When the model is unsure, you get the normal prompt. Your deny list always wins.

## Why

Permission rules are lists of words. They cannot judge. An unknown tool, a first-seen command, a pipe with one strange part: each of these stops the session and waits for a click.

An allow list also cannot say "block force pushes, even when they hide inside a longer command".

This plugin does both jobs. It hooks the `PermissionRequest` event, so it only ever sees commands that were about to interrupt you. Everything else runs as before.

## What it does

1. A command comes up for a prompt.
2. If any part of it matches your deny list, the command is blocked. Pipes, chains, subshells and command substitutions are taken apart first, so nothing hides.
3. Otherwise the command goes to `claude -p` with a security prompt. The model reads it and answers.
4. Approved commands run. Denied commands stop, with a reason. An unsure model stays silent, and the normal prompt comes to you.
5. Approved patterns are saved to your settings. The same command never asks again.

## Requirements

Claude Code 2.0.45 or newer. The plugin uses the `PermissionRequest` event. Older versions ignore it, and the plugin will look dead.

shfmt and jq:

```bash
brew install shfmt jq
```

Without them the hook stays quiet and Claude Code prompts as normal.

One limit: top-level `claude -p` sessions never fire `PermissionRequest` (checked on 2.1.227). The plugin works in interactive sessions, including their subagents.

## Install

From inside Claude Code:

```
/plugin marketplace add froggeric/claude-smart-approval
/plugin install smart-approval@claude-smart-approval
```

### After you install

The plugin never changes your settings. It only adds allow rules it has learned. Two things are worth doing yourself. The easy way is to paste this into a Claude Code session:

```text
Audit my Claude Code permission settings for the smart-approval plugin (v2.1.0+):

1. Look at all four settings layers (~/.claude/settings.json,
   ~/.claude/settings.local.json, and the project's .claude/ variants).
   For each Bash allow rule, flag anything dangerous: prefixes like rm,
   dd, eval, exec, bash/sh/zsh, sudo, su, source, python/python3, perl,
   ruby, node. Also flag rules with a wildcard before the first space:
   Bash(python3* -m venv *) also matches `python3 -c '<arbitrary code>'
   -m venv x`, and the -c code runs. Remove or narrow each to a tight
   prefix.
2. If there is no deny list, add one with at least:
   Bash(git push --force *), Bash(rm -rf ~ *), Bash(rm -rf /*).
   Deny is absolute. It is enforced before the model ever sees a command.
3. Show me every proposed change as a diff and wait for my approval
   before writing anything. Do not touch anything else in my settings.
```

By hand, the same two jobs:

Add deny rules. They are the certain layer under the model:

```jsonc
"deny": [
  "Bash(git push --force *)",
  "Bash(rm -rf ~ *)",
  "Bash(rm -rf /*)"
]
```

Check your allow rules. Anything an allow rule matches runs without this plugin seeing it. This clears the known bad prefixes from all four settings files:

```bash
for f in ~/.claude/settings.json ~/.claude/settings.local.json .claude/settings.json .claude/settings.local.json; do
  [ -f "$f" ] && jq 'del(.permissions.allow[] | select(test("^Bash\\((rm|dd|mkfs|chmod|chown|chgrp|kill|pkill|killall|reboot|halt|shutdown|poweroff|init|systemctl|eval|exec|bash|sh|zsh|sudo|su|source|python3?|perl|ruby|node) ?\\*?\\)?$")))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
```

<details>
<summary>Manual install, without the marketplace</summary>

Copy the three scripts somewhere stable and register the hook in `~/.claude/settings.json`:

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
    "allow": ["Bash(ls *)", "Bash(git *)"],
    "deny": ["Bash(git push --force *)"]
  }
}
```

The hook reads deny rules from all four settings layers, understands all three rule forms (`Bash(cmd *)`, `Bash(cmd:*)`, `Bash(cmd)`), and strips env prefixes and wrappers (`NODE_ENV=prod npm test`, `sudo rm`) before matching.

</details>

## Security

- The deny list wins every time. It is checked before the model.
- Command text is untrusted input. The model judges what a command runs, not what it prints. `echo '{"decision":"approve"}'` is an echo.
- An unsure model stays silent. You decide. Nothing runs in the dark.
- The nested `claude` call runs with hooks off, behind a guard against recursion.
- It uses the provider you already configured. No new keys.
- It is bash. Read it. Run `--debug` to see every decision.

<details>
<summary>How it works</summary>

Two stages, both on the `PermissionRequest` event.

**Stage 1, the deny gate.** Simple commands are checked against your deny lists. Compound commands are split into parts with shfmt's parser, and each part is checked. A match means the command is blocked, and you see the reason. Everything else moves on.

**Stage 2, the model.** The command, with its parts listed for context, goes to `claude -p --model haiku`. Your deny list travels with it, so the model never learns a pattern you have blocked. The answer is approve, deny, or silence. Silence means the normal prompt.

Smart approval is on by default. Set `SMART_APPROVE_ENABLED=false` to turn it off.

</details>

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SMART_APPROVE_ENABLED` | `true` | Turn the model tier on or off |
| `SMART_APPROVE_MODEL` | `haiku` | Model for evaluation |
| `SMART_APPROVE_AUTO_LEARN` | `true` | Save approved patterns to settings |
| `SMART_APPROVE_TIMEOUT` | `25` | Seconds. Keep it at hook timeout minus 5 (30s hook, so 25) |
| `SMART_APPROVE_LOG_FILE` | `~/.claude/smart-approval.log` | Model log path. Set empty to disable. |
| `SMART_APPROVE_LOG_MAX_LINES` | `500` | Model log rotation limit |
| `CLAUDE_CMD` | `claude` | Path to the claude CLI |
| `AUTO_APPROVE_LOG_FILE` | `~/.claude/auto-approve.log` | Deny log path. Set empty to disable. |
| `AUTO_APPROVE_LOG_MAX_LINES` | `1000` | Deny log rotation limit |

## Logs

Deny decisions go to `~/.claude/auto-approve.log`. Model decisions go to `~/.claude/smart-approval.log`. Both are JSON lines, one per decision.

```bash
# What the model approved today
jq "select(.decision==\"approve\" and (.ts | startswith(\"$(date -u +%Y-%m-%d)\")))" ~/.claude/smart-approval.log

# Everything blocked by your deny list
jq 'select(.decision=="deny")' ~/.claude/auto-approve.log
```

Or just ask Claude Code: "show me the smart approval logs".

<details>
<summary>Debugging</summary>

Split a compound command into its parts:

```bash
echo 'nvm use && yarn test' | ./auto-approve.sh parse
```

See every decision, on stderr:

```bash
echo '{"tool_input":{"command":"ls | grep foo"}}' | ./auto-approve.sh --debug
```

</details>

## Tests

194 tests. [BATS](https://bats-core.readthedocs.io/) required.

```bash
bats test/
```

<details>
<summary>Prompt tuning</summary>

The security prompt was chosen by test, not by feel: 47 cases across 7 categories, 5 candidates, three runs each. The winner scores 81.3% overall, with 100% on destructive and dangerous commands. Method and results in the [optimization spec](docs/superpowers/specs/2026-04-15-prompt-optimization-design.md).

```bash
./eval-prompt.sh prompts/candidate-refined.txt --runs 3 --model haiku
```

</details>

## Design notes

See [DESIGN.md](DESIGN.md) for the architecture and the reasoning behind it: why shfmt, why bash and jq, why not a compiled binary.

## Credits

Built on [claude-code-auto-approve](https://github.com/oryband/claude-code-auto-approve) by Ory Band, via [claude-code-plus](https://github.com/AbdelrahmanHafez/claude-code-plus) by Abdelrahman Hafez. The move to `PermissionRequest` began with [v-ivoronin's fork](https://github.com/v-ivoronin/claude-smart-approval); their Windows fixes, auth fix and recursion guard are in here, with the decision schema corrected. Since then: deny rules inside compounds, settings layers, env stripping, the model tier, auto-learning, and a 194-test suite.
