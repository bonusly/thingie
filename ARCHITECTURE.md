# Thingie Architecture

## Goals

- Approve a pull request only when GitHub Copilot's review approved its current commit.
- Decide deterministically: every rule reads GitHub API state; Thingie makes no LLM calls.
- Fail safe: anything Thingie can't determine (PR size, a file's content, a review state) blocks approval.
- Never check out or run the PR's code.

## Command surface

| Command | Purpose |
|---|---|
| `thingie approve` | Evaluate the rules for one PR and approve, dismiss, or explain |
| `thingie version` | Print the installed version |

## Flow

```
thingie approve
      |
      v
Configuration  (lib/thingie/config/default.toml + .thingie/config.toml)
      |
      v
GitHub::Context (GITHUB_REPOSITORY, the event payload) or --gh-repo/--pr
      |
      v
GitHub::Approver
  1. skip?  draft, skip label, self-approval, approval_team
  2. block reasons
       - Copilot's latest review is APPROVED on the head commit
       - .thingie/config.toml and protected_paths unchanged
       - change size within max_changes
       - ObfuscationDetector finds nothing in changed files (read via the contents API)
       - no human CHANGES_REQUESTED
       - LinkedRuns: linked Actions runs came from the default branch
  3. apply   approve the head commit / dismiss stale Thingie approvals
  4. status comment upserted (blocked/skipped) or removed (approved)
      |
      v
Stats::Emitter  approval.decided event to configured sinks
```

## Components

- `CLI` (`cli.rb`): Thor commands; builds the approver and emits the stats event.
- `Configuration` (`configuration.rb`): bundled defaults deep-merged with the project's `.thingie/config.toml`, then explicit overrides. Also loads `~/.thingie/.env` into the environment without replacing variables already set.
- `GitHub::Approver` (`github/approver.rb`): the rules and the GitHub writes. Reads use the main token; writes try the main token, then the resolve-token PAT.
- `GitHub::LinkedRuns` (`github/linked_runs.rb`): checks linked Actions runs against their repository's default branch.
- `GitHub::Context` (`github/context.rb`): repository and PR number from the Actions environment.
- `ObfuscationDetector` (`obfuscation_detector.rb`): pattern-based scan of file contents, pure and side-effect free.
- `Stats` (`stats.rb`, `stats/`): fail-open event sinks (`jsonl`, `command`, plugins).

## Testing strategy

- Octokit is replaced with `instance_double(Octokit::Client)`; no spec calls GitHub.
- Environment variables are read through `Thingie::Env`, never `ENV` directly, so specs stub a clean env via `spec_helper` instead of mutating the real process environment.
- `yard_coverage_spec` keeps every public method documented with matching `@param` tags.
