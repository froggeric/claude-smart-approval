# approve-compound-bash

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) hook that auto-approves compound Bash commands when every sub-command is in your allow list and none are in your deny list.

## The problem

Claude Code matches `Bash(cmd *)` permissions against the **full command string**. `ls | grep foo` doesn't match `Bash(ls *)` or `Bash(grep *)`, so you get prompted even though both commands are individually allowed. Same for `nvm use && yarn test`, `git log | head`, `mkdir -p dir && cd dir`, etc.

This hook parses compound commands into segments and checks each one.

## Install

Requires **bash 4.3+** (auto-detected; re-execs with Homebrew bash on macOS if needed), [shfmt](https://github.com/mvdan/sh), [jq](https://jqlang.github.io/jq/), and optionally the [claude CLI](https://docs.anthropic.com/en/docs/claude-code) for smart approval.

```bash
brew install shfmt jq
```

Copy the script somewhere and register it in `~/.claude/settings.json`:

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

The hook reads permissions from all settings layers (global, global local, project, project local), supports all permission formats (`Bash(cmd *)`, `Bash(cmd:*)`, `Bash(cmd)`), and strips env var prefixes (`NODE_ENV=prod npm test` matches `npm`).

## How it decides

**Simple commands** (no `|`, `&`, `;`, `` ` ``, `$(`) are checked directly against your prefix lists. No parsing overhead.

**Compound commands** are parsed into a JSON AST by shfmt, walked by a jq filter that extracts every sub-command (including inside `$(...)`, `<(...)`, subshells, if/for/while/case bodies, `bash -c` arguments, etc.), then each segment is checked.

Three outcomes:

- **Approve** — all segments in allow list, none in deny list. Command runs.
- **Deny** — any segment matches the deny list. Command is blocked.
- **Fall through** — segment is unknown (not in allow or deny), or parse failed. Claude Code shows its normal permission prompt.

On any error the hook falls through. It never approves something it can't fully analyze.

## Smart approval (Stage 2)

When Stage 1 falls through (unknown command, not in allow or deny lists), the hook can optionally evaluate the command using a headless `claude -p` instance. This is useful for long autonomous sessions where prompting the user isn't practical.

**How it works:** The unknown command is sent to `claude -p --model haiku` with a security evaluation prompt. The AI decides whether to approve, deny, or ask (escalate to you with its analysis). Approved patterns are optionally auto-learned to your settings files so future matches are instant.

**Configuration (environment variables):**

| Variable | Default | Description |
|----------|---------|-------------|
| `SMART_APPROVE_ENABLED` | `true` | Enable/disable smart approval |
| `SMART_APPROVE_MODEL` | `haiku` | Model for evaluation (fast/cheap recommended) |
| `SMART_APPROVE_AUTO_LEARN` | `true` | Auto-learn approved patterns to settings |
| `SMART_APPROVE_TIMEOUT` | `25` | Timeout in seconds for the claude call |
| `CLAUDE_CMD` | `claude` | Path to claude CLI binary |

**Security:** The evaluation prompt explicitly treats the command content as untrusted input. The AI is instructed to evaluate safety, not to follow instructions embedded in the command.

**Performance:** ~8–13 seconds per evaluation with haiku. The hook timeout is set to 30s to accommodate this. Set `SMART_APPROVE_ENABLED=false` to disable.

**Provider-agnostic:** Uses `claude -p` which inherits your configured provider (z.ai, ollama, etc.), not the Anthropic API directly.

## Debugging

Extract sub-commands from a compound command:

```bash
echo 'nvm use && yarn test' | ./approve-compound-bash.sh parse
# nvm use
# yarn test
```

Verbose mode shows matching decisions on stderr:

```bash
echo '{"tool_input":{"command":"ls | grep foo"}}' | ./approve-compound-bash.sh --debug
```

## Testing

145 tests across parsing, permissions, security, smart approval, auto-learn, and integration. Requires [BATS](https://bats-core.readthedocs.io/).

```bash
bats test/
```

## Known limitations

**`bash -c` on simple path**: `bash -c 'echo hello'` has no shell metacharacters, so it takes the fast path and matches against the prefix list as-is without recursing into the inner command. Don't add `bash`, `sh`, or `zsh` to your allow list.

## Design decisions

**Why this hook exists.** Claude Code evaluates `Bash(cmd *)` permissions against the full command string. Compound commands like `ls | grep foo` or `nvm use && yarn test` don't match individual prefix rules, so users get prompted even when every sub-command is already allowed. As of March 2026, this remains an [open](https://github.com/anthropics/claude-code/issues/29491) [issue](https://github.com/anthropics/claude-code/issues/4236) with no native fix.

**Why bash + shfmt + jq.** Claude Code plugins are expected to be [transparent and auditable](https://code.claude.com/docs/en/discover-plugins) — compiled binaries and obfuscated code are explicitly discouraged. A bash script with well-known dependencies meets this standard. shfmt and jq are both small, fast, and available via standard package managers.

**Why shfmt for parsing.** [shfmt](https://github.com/mvdan/sh) (`mvdan.cc/sh`) is the most complete and battle-tested bash parser available. Its JSON AST output covers all compound constructs: pipes, chains, subshells, command/process substitution, control flow, and declarations. Alternatives like [tree-sitter-bash](https://github.com/tree-sitter/tree-sitter-bash) are designed for editor highlighting rather than semantic analysis, and hand-written parsers (as used by [Dippy](https://github.com/ldayton/Dippy)) trade external dependencies for ongoing maintenance burden and potential correctness gaps.

**Why not a compiled binary.** A Go rewrite using `mvdan.cc/sh` as a library would eliminate the shfmt and jq subprocesses, but would produce an opaque binary that conflicts with the plugin ecosystem's source-readability expectations. The current approach adds ~100–150ms of subprocess overhead per compound command, well within Claude Code's hook timeout defaults.

## Credits

Based on [claude-code-plus](https://github.com/AbdelrahmanHafez/claude-code-plus) (MIT). Key differences: deny list support, active deny for compounds, fast path for simple commands, falls through on empty parse (the original approves), settings layer support, env var stripping, and a test suite.
