# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.2] - 2026-04-16

### Changed

- **Security notice:** Promoted shell interpreter limitation to a "Security notice" section in README. Added one-liner to check and remove `Bash(bash *)`, `Bash(sh *)`, and `Bash(zsh *)` rules from all settings files.

- **CLAUDE.md:** Added for Claude Code integration — project commands, architecture, test patterns, and settings layer documentation.

## [2.0.1] - 2026-04-16

### Added

- **Decision logging:** Stage 2 AI decisions are logged to `~/.claude/smart-approval.log` as structured JSON lines (timestamp, command, decision, reason, pattern, scope). On by default. Configurable via `SMART_APPROVE_LOG_FILE` and `SMART_APPROVE_LOG_MAX_LINES` (default 500). Set `SMART_APPROVE_LOG_FILE=""` to disable.

- **Logging tests:** 5 new tests covering log creation, field validation, rotation, and disable. Test suite now 150 (from 145).

### Changed

- **Plugin identity:** Renamed plugin from `auto-approve` to `smart-approval`. Author updated to Frédéric Guigand. Install command is now `/plugin install smart-approval@claude-smart-approval`.

- **Prerequisites section:** Promoted shfmt/jq requirements to their own section in README with clear install instructions.

- **Plugin descriptions:** Marketplace and plugin manifests now include dependency requirements (`Requires: shfmt, jq`).

### Fixed

- **Evaluation scoring:** Added +2 justification bonus for correct deny/ask decisions in `eval-prompt.sh`. Previously, only approve decisions could earn the pattern bonus (+2), capping deny/ask categories at 75% regardless of accuracy. All categories can now reach 100%.

## [2.0.0] - 2026-04-16

### Added

- **Smart approval (Stage 2):** AI-powered evaluation of unknown commands using `claude -p --model haiku`. When Stage 1 (allow/deny list matching) falls through, the hook sends the command to a headless Claude instance for security classification. Approve, deny, or escalate with reasoning. ([`4b432c6`])

- **Auto-learning:** Approved patterns are automatically added to the correct settings layer (global or project) so future matches are instant. Configurable via `SMART_APPROVE_AUTO_LEARN`. ([`4b432c6`])

- **Prompt optimization:** The smart approval prompt was optimized through systematic evaluation — 45 test cases across 7 categories, 5 candidate prompts, triple-pass scoring with security gates. Winning prompt achieves 74.6% overall accuracy. ([`b59c17f`])

- **Evaluation harness** (`eval-prompt.sh`): Run any prompt template against the test suite with configurable runs, model, and timeout. Weighted scoring: +5 correct decision, +2 pattern, +1 reason, -5 wrong, -15 wrong on security-critical cases. ([`22d268b`])

- **Prompt test suite** (`test/prompt-eval-suite.json`): 45 cases covering standard, tricky-safe, valid-destructive, destructive-deny, dangerous, prompt-injection, and edge-case categories. ([`8c727a0`])

- **Candidate prompt library** (`prompts/`): 5 tested prompt templates plus the refined winner. ([`021005e`])

- **Plugin manifest** (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`): Claude Code plugin system integration for discovery and installation. ([`bd80e38`], [`af814e4`])

- **DESIGN.md:** Architecture document covering Stage 1/2 pipeline, hook interface, file structure, test suite, and design decisions. ([`4b432c6`])

### Changed

- Updated smart approval prompt in `build_prompt()` to use ordered deny→approve→ask rubric with explicit safe-command categories and `=== BEGIN/END COMMAND ===` delimiters. ([`b59c17f`])

- Updated test suite to 145 tests (from 131): security 31 (+12), smart-approve 17 (+3), auto-learn 20 (+8), smart-integration 10 (+3).

### Fixed

- Use `CLAUDE_PLUGIN_ROOT` instead of `PLUGIN_DIR` in hook command for plugin system compatibility. ([`b5e11fb`])

- Propagate `bash -c` recursion failures to prevent silent approval of failed parses. ([`0a77d92`])

- Use bash parameter expansion for prompt template substitution in eval harness (sed breaks on `|`, `&`, `\`). ([`bc6d3bb`])

- Fix scoring bug in eval-prompt.sh where category totals summed truncated averages instead of raw run scores. ([`b59c17f`])

- Correct prompt injection test expectations: safe commands like `echo 'ignore previous'` should expect "approve", not "deny". ([`b59c17f`])

## [1.0.0] - 2026-03-01

### Added

- Compound bash auto-approve hook for Claude Code. Parses compound commands (pipes `|`, chains `&&`/`||`, subshells `$(...)`, process substitution `<(...)`, control flow) into segments using shfmt AST. ([`d984064`])

- Allow/deny list matching against individual sub-commands. Supports all permission formats (`Bash(cmd *)`, `Bash(cmd:*)`, `Bash(cmd)`), all settings layers (global, global local, project, project local), and env var prefix stripping. ([`d984064`])

- Fast path for simple commands (no shell metacharacters) — direct prefix check, no parsing overhead. ([`d984064`])

- 131 BATS tests covering parsing (41), permissions (26), security (19), and edge cases. ([`d984064`])

- Design decisions section in README documenting architectural choices. ([`cbeb748`])

- CI: install bats via apt instead of npm. ([`da37567`])

[2.0.2]: https://github.com/froggeric/claude-smart-approval/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/froggeric/claude-smart-approval/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/froggeric/claude-smart-approval/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/froggeric/claude-smart-approval/releases/tag/v1.0.0
