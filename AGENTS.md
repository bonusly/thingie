# AGENTS.md

This file provides guidance to AI coding agents (Codex, Copilot, Cursor, etc.) when working with code in this repository.

## What This Is

Thingie is a deterministic pull request auto-approver and GitHub Action. It approves a PR when GitHub Copilot's latest review approves the PR's current commit and a set of safety rules pass. It makes no LLM calls and posts no review comments.

## Commands

```bash
bundle install                                           # install dependencies
bundle exec rake                                         # full CI: RuboCop + RSpec
bundle exec rspec                                        # tests only
bundle exec rspec spec/thingie/configuration_spec.rb:17  # single test by line number
bundle exec rubocop                                      # lint
bundle exec rubocop -A                                   # auto-fix lint
```

Always run `bundle exec rake` before committing to ensure both linting and tests pass.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md). In short:

1. **CLI** (`lib/thingie/cli.rb`) — Thor commands: `approve` and `version`.
2. **Configuration** (`lib/thingie/configuration.rb`) — bundled defaults deep-merged with `.thingie/config.toml`, then explicit overrides.
3. **Approver** (`lib/thingie/github/approver.rb`) — the approval rules, the approve/dismiss writes, and the status comment.
4. **ObfuscationDetector** (`lib/thingie/obfuscation_detector.rb`) — pattern scan of changed files' content, which the Approver reads through the GitHub API.
5. **Stats** (`lib/thingie/stats/`) — fail-open `approval.decided` event sinks.

## Code Conventions

- Fail safe: when Thingie can't determine something a rule depends on, the rule blocks.
- `pr` is explicitly allowed as a parameter name in `.rubocop.yml`.
- RuboCop limits: 65-line methods, 120-line classes, 120-char lines. Block length cop is disabled for specs and gemspec.
- RSpec uses `expect()` syntax with no monkey-patching. Specs stub Octokit — no GitHub token required.
- Specs isolate from `~/.thingie/.env` to avoid developer environment leakage.
