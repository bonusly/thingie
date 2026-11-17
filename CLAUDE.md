# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Thingie is a deterministic pull request auto-approver and GitHub Action. It approves a PR when GitHub Copilot's latest review approves the PR's current commit and a set of safety rules pass. It makes no LLM calls and posts no review comments; up to 0.11 it also ran its own LLM review, which 0.12.0 removed.

## Commands

```bash
bundle install          # install deps
bundle exec rake        # RuboCop + RSpec (default CI task)
bundle exec rspec       # tests only
bundle exec rspec spec/thingie/configuration_spec.rb:17  # single test by line
bundle exec rubocop     # lint
bundle exec rubocop -A  # auto-fix
```

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the flow. The pieces:

- **`CLI`** (`cli.rb`) — `approve` builds a `GitHub::Approver` from `[approve]` config and the Actions context, runs it, and emits the `approval.decided` stats event. `version` prints the version.
- **`Configuration`** (`configuration.rb`) — bundled defaults (`config/default.toml`) deep-merged with `.thingie/config.toml`, then explicit overrides. Loads `~/.thingie/.env` into `Thingie::Env` without replacing variables already set.
- **`GitHub::Approver`** (`github/approver.rb`) — skips (draft, skip label, self-approval, `approval_team`) or blocks unless: Copilot's latest review is `APPROVED` on the head commit, no config or protected-path change, size within `max_changes`, no obfuscated code, no human `CHANGES_REQUESTED`, linked runs came from the default branch. Approves the evaluated commit, dismisses stale Thingie approvals, and keeps one status comment.
- **`ObfuscationDetector`** (`obfuscation_detector.rb`) — pure pattern scan over `{path => content}`.
- **`GitHub::LinkedRuns`**, **`GitHub::Context`**, **`Stats`** — linked-run checks, Actions context, fail-open event sinks.

## Key Domain Concepts

- Copilot's verdict is its review **state**, read from the API: `APPROVED` for "Approval recommended", `COMMENTED` for "Changes recommended". Never parse review text.
- Copilot is identified by login `copilot-pull-request-reviewer[bot]` **and** user type `Bot`.
- Fail safe: anything a rule can't determine blocks.
- `pr` is allowed as a parameter name in RuboCop config.
- RuboCop limits: 65-line methods, 120-line classes, 120-char lines. Block length cop is disabled for specs and gemspec.

## Configuration

Project config lives in `.thingie/config.toml`:

```toml
[approve]
enabled = true
max_changes = 500
protected_paths = [".thingie/**/*", "app/billing/**"]
approval_team = "bonusly/pr-auto-approval"
```
