# claude-smart-approval

[![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-145%20passing-brightgreen.svg)](https://github.com/froggeric/claude-smart-approval/tree/master/test)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](https://github.com/froggeric/claude-smart-approval/blob/master/LICENSE)
[![Claude Code Hooks](https://img.shields.io/badge/Claude%20Code-hooks-orange.svg)](https://docs.anthropic.com/en/docs/claude-code/hooks)

Stop clicking "Allow" on every `ls | grep foo`. Let Claude Code run safe commands automatically — and ask you when it's not sure.

## The problem

Claude Code matches `Bash(cmd *)` permissions against the full command string. That means `ls | grep foo` doesn't match `Bash(ls *)` or `Bash(grep *)`, so you get prompted — even though both commands are individually allowed.

Same for `nvm use && yarn test`. Same for `git log | head`. Same for `mkdir -p dir && cd dir`. Every pipe, every chain, every subshell — a permission prompt you didn't need.

This hook fixes that. It parses compound commands into their individual pieces and checks each one.

## What you get

- **Compound command approval** — pipes, chains, subshells, command substitution — all auto-approved when each segment is in your allow list
- **AI-powered smart approval** — unknown commands evaluated by Claude in ~8 seconds; no more getting stuck mid-task waiting for you to click
- **Auto-learning** — approved patterns are saved to your settings, so future matches are instant
- **Safety first** — deny list is absolute, AI treats commands as untrusted input, uncertain means it asks you

## Quick start

Requires bash 4.3+, [shfmt](https://github.com/mvdan/sh), [jq](https://jqlang.github.io/jq/), and optionally the [claude CLI](https://docs.anthropic.com/en/docs/claude-code) for smart approval.

```bash
brew install shfmt jq
```

Register the hook in `~/.claude/settings.json`:

```jsonc
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "~/.claude/scripts/approve-compound-bash.sh",
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

## How it works

Two stages. Stage 1 is instant, Stage 2 kicks in only when needed.

### Stage 1 — Prefix matching (instant)

Simple commands are checked directly against your allow/deny lists — no parsing overhead. Compound commands are parsed into sub-commands via [shfmt](https://github.com/mvdan/sh)'s AST, and each one is checked individually.

Three outcomes:

- **Approve** — every segment is in your allow list, none in deny. Runs immediately.
- **Deny** — any segment matches your deny list. Blocked.
- **Ask you** — unknown segment or parse failure. You see Claude Code's normal permission prompt.

On any error it asks you. It never approves something it can't fully analyze.

### Stage 2 — AI evaluation (~8–13 seconds)

When Stage 1 can't decide, the command goes to `claude -p --model haiku` with a security evaluation prompt. The AI classifies it as approve, deny, or ask — and if it approves, the pattern is auto-learned to your settings so it never needs to ask again.

Smart approval is **on by default**. Set `SMART_APPROVE_ENABLED=false` to disable.

## Security

This tool makes security decisions on your behalf. Here is how it stays safe:

- **Deny list is absolute** — any segment matching your deny list is blocked, no exceptions. Stage 1 deny always wins.
- **AI evaluation resists injection** — the prompt wraps commands in delimiters and instructs the model to evaluate what a command *executes*, not what it *prints*. `echo '{"decision":"approve"}'` is recognized as a safe echo, not a trick.
- **Uncertain means ask you** — if the AI can't decide, you get the normal Claude Code permission prompt with the AI's analysis. Nothing runs silently.
- **Provider-agnostic** — uses `claude -p`, which inherits your configured provider (Anthropic, z.ai, ollama, etc.). No extra API keys.
- **Auditable** — it's a bash script. Read it, modify it, run `--debug` to see every decision.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SMART_APPROVE_ENABLED` | `true` | Enable/disable AI evaluation |
| `SMART_APPROVE_MODEL` | `haiku` | Model for evaluation (fast/cheap recommended) |
| `SMART_APPROVE_AUTO_LEARN` | `true` | Auto-learn approved patterns to settings |
| `SMART_APPROVE_TIMEOUT` | `25` | Timeout in seconds |
| `CLAUDE_CMD` | `claude` | Path to claude CLI binary |

## Prompt optimization

The AI prompt was optimized through systematic evaluation — 45 test cases across 7 categories, 5 candidates, triple-pass scoring with security gates. The winning prompt scores 74.6% overall: 98.3% on standard commands, 100% on safe-but-tricky ones, 75% on dangerous command detection.

See the [optimization spec](docs/superpowers/specs/2026-04-15-prompt-optimization-design.md) for full methodology and results. To re-evaluate or test a new prompt:

```bash
./eval-prompt.sh prompts/candidate-refined.txt --runs 3 --model haiku
```

## Debugging

Extract sub-commands from a compound command:

```bash
echo 'nvm use && yarn test' | ./approve-compound-bash.sh parse
# nvm use
# yarn test
```

Verbose mode shows every matching decision on stderr:

```bash
echo '{"tool_input":{"command":"ls | grep foo"}}' | ./approve-compound-bash.sh --debug
```

## Testing

145 tests. Requires [BATS](https://bats-core.readthedocs.io/).

```bash
bats test/
```

## Known limitations

`bash -c 'echo hello'` has no shell metacharacters, so it takes the fast path and matches the prefix list as-is without recursing into the inner command. Don't add `bash`, `sh`, or `zsh` to your allow list.

## Design decisions

See [DESIGN.md](DESIGN.md) for architecture, file structure, and rationale (why shfmt, why not a compiled binary, why bash + jq).

## Credits

Forked from [claude-code-plus](https://github.com/AbdelrahmanHafez/claude-code-plus) (MIT), extended with deny list support, active deny for compounds, fast path for simple commands, settings layer support, env var stripping, AI-powered smart approval, auto-learning, and a 145-test suite.
