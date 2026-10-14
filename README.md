# claude-smart-approval

[![Version](https://img.shields.io/badge/version-2.2.0-blue.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-211%20passing-brightgreen.svg)](https://github.com/froggeric/claude-smart-approval/tree/master/test)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/LICENSE)
[![Claude Code Hooks](https://img.shields.io/badge/Claude%20Code-hooks-orange.svg)](https://code.claude.com/docs/en/hooks)

Claude Code asks before it runs a command it doesn't know. That is a sensible default, and in a long session it also means you spend the evening clicking Allow. This plugin answers for you: a small model reads each unknown command, the safe ones run, the dangerous ones are blocked, and when the model is unsure you get the normal prompt and decide yourself.

**Your deny list always wins.** A command is blocked before the model ever sees it, even when the offending part hides inside a pipe, a chain or a subshell.

**A model judges the rest.** Unknown commands go to `claude -p` (haiku by default), which returns one of three answers: run it, block it, or I'm not sure.

**Silence means you.** An unsure model produces no decision at all, so Claude Code shows you the prompt it was about to show anyway. Nothing runs in the dark.

**It learns.** Approved patterns are saved to your settings, so any given command asks at most once.

## Why you might want it

Permission rules are lists of words. They match, or they don't, and the ones that don't match stop the session: an unfamiliar tool, a first-seen command, a pipe with one odd segment. Most are harmless, but all of them wait for you.

A rule list also cannot express the things you actually want to say, such as "block force pushes, even when they hide inside a longer command". This plugin does both jobs. It rides the `PermissionRequest` event, so it only ever sees commands that were about to interrupt you; everything else runs exactly as before, with no extra work and no extra latency.

## How it decides

When Claude Code is ready to prompt you, the hook takes over and works through two quick stages.

First, the deny gate. The command is split into its parts with shfmt's parser, and if any part matches one of your deny rules, the whole command stops there, with the reason shown to you. Your rules are read from all four settings layers, and env prefixes and wrappers (`NODE_ENV=prod npm test`, `sudo rm`) are stripped before matching, so nothing slips past on a technicality.

Next, your own allow rules get a turn. Claude Code prompts for compound commands rather than matching their parts against allow rules, so a pipe between two commands you trust still lands here. If every part of the compound matches an allow rule, it is approved on the spot, with no model call: you already trust each part, so the whole is no riskier than its pieces. Bare rules (`Bash(git status)`) match exactly; starred rules (`Bash(git *)`) match as prefixes, the same distinction Claude Code itself makes.

Otherwise the command goes to the model, with its parts listed for context and your deny rules attached. This takes around eight seconds. Approve, and the command runs. Deny, and it stops with the reason. Unsure, and the plugin says nothing: the normal prompt appears, and you decide.

<details>
<summary>Stage by stage, in detail</summary>

**Stage 1, the deny gate and the allow fast path.** Simple commands are checked directly against your deny lists. Compound commands are split into parts with shfmt's parser: pipes, chains, subshells, and command and process substitution are all unpacked, and each part is checked on its own. A match anywhere means the command is denied outright. The remaining parts are then checked against your allow rules: a compound whose every part matches is approved locally, without a model call (bare rules match exactly, starred rules as prefixes). The rest moves on to Stage 2.

**Stage 2, the model.** The command, with its parts listed for context, goes to `claude -p --model haiku` with a security evaluation prompt. Your deny list travels with it, so the model never learns a pattern you have blocked. The answer is approve (the command runs and the pattern is auto-learned), deny (blocked, reason surfaced), or silence (the native prompt escalates to you).

Smart approval is on by default. Set `SMART_APPROVE_ENABLED=false` to turn it off.

</details>

## Safety

This tool runs commands on your behalf, so it is built to fail towards asking you.

- **The deny list is absolute.** It is checked before the model, and it cannot be talked around, because the model never sees a denied command.
- **Command text is untrusted input.** The model is told to judge what a command executes, not what it prints. `echo '{"decision":"approve"}'` is recognised as an echo, not a trick, and injection-style lines are stripped from the prompt before it is sent.
- **Uncertainty is silence.** If the model can't decide, the plugin emits nothing and the normal prompt comes to you.
- **The nested session is locked down.** Stage 2 shells out to `claude -p` with hooks disabled inside it, behind a recursion guard, with effort pinned low and ultracode off, and with skills, MCP servers and CLAUDE.md memory kept out of it — so neither your global settings nor your project's context files can slow the classifier down or leak into its judgement.
- **No new secrets.** It uses whatever provider your `claude` CLI is already configured with.
- **It's bash.** Three scripts you can read in an afternoon, with a debug mode that prints every decision.

## Requirements

**Claude Code 2.0.45 or newer.** The plugin rides the `PermissionRequest` event, which older versions ignore. If you're below 2.0.45, the plugin will look dead: nothing breaks, but nothing happens either.

You also need shfmt and jq:

```bash
brew install shfmt jq
```

Without them the hook stays quiet and Claude Code prompts as normal.

On macOS, GNU coreutils is recommended as well:

```bash
brew install coreutils
```

Stage 2 wraps its model call in `gtimeout` (coreutils' `timeout`) so a hung or slow provider is killed after 25 seconds. Without it the call still works, but nothing caps it short of the hook's own 30-second ceiling: a slow evaluation surfaces as a permission prompt, and each stuck one leaves an orphaned `claude` process behind.

**One known limit:** top-level headless `claude -p` sessions never fire `PermissionRequest` (verified on 2.1.227). The plugin works in interactive sessions, including their subagents. If you live in scripts and cron jobs, this is not the tool for that.

## Install

From inside Claude Code:

```
/plugin marketplace add froggeric/claude-smart-approval
/plugin install smart-approval@claude-smart-approval
```

### After you install: two adjustments worth making

The plugin never edits your settings; the only thing it ever writes is an allow rule it has learned. These two changes are yours to make, and they matter.

The easy way is to paste this into a Claude Code session and let it do the work for you:

```text
Audit my Claude Code permission settings for the smart-approval plugin (v2.2.0+):

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

If you'd rather work by hand, the same two jobs:

**Add deny rules.** They are the certain layer beneath the model's judgement, and they cost you nothing to be generous with:

```jsonc
"deny": [
  "Bash(git push --force *)",
  "Bash(rm -rf ~ *)",
  "Bash(rm -rf /*)"
]
```

**Check your allow rules.** This matters more than it used to: anything an allow rule matches now runs without this plugin seeing it, so a loose rule is an open door. This one-liner clears the known bad prefixes from all four settings files:

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

The hook understands all three rule forms (`Bash(cmd *)`, `Bash(cmd:*)`, `Bash(cmd)`).

</details>

## Configuration

Everything has a sensible default. The two you're most likely to touch are the model and the off switch.

| Variable | Default | Description |
|----------|---------|-------------|
| `SMART_APPROVE_ENABLED` | `true` | Turn the model tier on or off |
| `SMART_APPROVE_MODEL` | `haiku` | Model for evaluation |
| `SMART_APPROVE_AUTO_LEARN` | `true` | Save approved patterns to settings |
| `SMART_APPROVE_TIMEOUT` | `25` | Seconds. Keep it at hook timeout minus 5 (30s hook, so 25) |
| `SMART_APPROVE_LOG_FILE` | `~/.claude/smart-approval.log` | Model log path. Set empty to disable. |
| `SMART_APPROVE_LOG_MAX_LINES` | `500` | Model log rotation limit |
| `CLAUDE_CMD` | `claude` | Path to the claude CLI |
| `AUTO_APPROVE_LOG_FILE` | `~/.claude/auto-approve.log` | Stage 1 log path (deny and compound-allow decisions). Set empty to disable. |
| `AUTO_APPROVE_LOG_MAX_LINES` | `1000` | Deny log rotation limit |

## What it did, and when

Every decision is written down. Deny-gate and compound-allow decisions land in `~/.claude/auto-approve.log`; model decisions land in `~/.claude/smart-approval.log`. Both are JSON lines, one per decision, and they rotate on their own.

```bash
# What the model approved today
jq "select(.decision==\"approve\" and (.ts | startswith(\"$(date -u +%Y-%m-%d)\")))" ~/.claude/smart-approval.log

# Everything blocked by your deny list
jq 'select(.decision=="deny")' ~/.claude/auto-approve.log
```

Or simply ask Claude Code: "show me the smart approval logs".

<details>
<summary>Debugging</summary>

Split a compound command into its parts:

```bash
echo 'nvm use && yarn test' | ./auto-approve.sh parse
```

See every decision as it happens, on stderr:

```bash
echo '{"tool_input":{"command":"ls | grep foo"}}' | ./auto-approve.sh --debug
```

</details>

<details>
<summary>Tests</summary>

211 of them. Run CI manually from the Actions tab; the push trigger is currently inert. You'll need [BATS](https://bats-core.readthedocs.io/):

```bash
bats test/
```

</details>

<details>
<summary>How the prompt was tuned</summary>

The security prompt was chosen by test, not by feel: 47 cases across 7 categories, 5 candidates, three runs each. The winner scores 81.3% overall, with 100% on destructive and dangerous commands. The method and full results live in the [optimization spec](docs/superpowers/specs/2026-04-15-prompt-optimization-design.md), and you can re-run the election yourself:

```bash
./eval-prompt.sh prompts/candidate-refined.txt --runs 3 --model haiku
```

</details>

## Design notes

[DESIGN.md](DESIGN.md) covers the architecture and the reasoning behind it: why shfmt for parsing, why bash and jq instead of a compiled binary, and what the two stages owe to each other.

## Credits

Built on [claude-code-auto-approve](https://github.com/oryband/claude-code-auto-approve) by Ory Band, via [claude-code-plus](https://github.com/AbdelrahmanHafez/claude-code-plus) by Abdelrahman Hafez. The move to `PermissionRequest` began with [v-ivoronin's fork](https://github.com/v-ivoronin/claude-smart-approval); their Windows fixes, the auth fix and the recursion guard are all in here, with the decision schema corrected to the documented form. Since then: deny rules inside compounds, settings layers, env stripping, the model tier, auto-learning, and a 211-test suite.
