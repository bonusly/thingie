# Thingie: approves pull requests that Copilot approved

Thingie is a deterministic pull request auto-approver. It approves a PR when
GitHub Copilot code review approves the PR's current commit and a set of safety
rules all pass. It makes no LLM calls of its own and posts no review comments:
Copilot does the review, Thingie decides whether that review, plus the rules
below, is enough for an approval.

Copilot reports its verdict as a review state, not just text: "Approval
recommended" is submitted as an `APPROVED` review and "Changes recommended" as
a `COMMENTED` one. A review's state can't be edited after it's submitted (only
its body can), and logins ending in `[bot]` are reserved for GitHub Apps, so
Thingie reads the state from the API and never parses the review text.

Thingie versions up to 0.11 also ran their own LLM code review. That was
removed in 0.12.0; pin an earlier tag if you still need it.

## How it decides

Thingie skips (leaves any existing approval alone) when the PR:

- is a draft or carries the `skip_label` (default `thingie-skip-approve`);
- is authored by the identity Thingie approves as;
- has an author outside `approval_team`, when that's set (a bot listed in
  `approval_bots` is eligible too).

Otherwise it approves only when **all** of these hold, and blocks (dismissing
its own earlier approvals) when any fails:

- **Copilot approved the current commit.** The latest review by
  `copilot-pull-request-reviewer[bot]` (a `Bot` account) is `APPROVED` and was
  submitted on the PR's head commit. Copilot not having reviewed yet, having
  reviewed an older commit, recommending changes, or having its approval
  dismissed all block.
- The PR doesn't change `.thingie/config.toml`, so it can't weaken the rules
  and wave itself through.
- No changed file matches a `protected_paths` glob.
- Additions plus deletions are within `max_changes` (an unknown size blocks).
- No changed file holds obfuscated code: long hex or base64 blobs, any
  `eval`-family call, strings built from character codes, or dense escape runs.
  Thingie reads each changed file's full content at the head commit through the
  API, so the PR's code is never checked out. A file it can't read blocks.
- No human reviewer's current review is `CHANGES_REQUESTED` (a later approval
  or dismissal by that reviewer clears it; an unreadable review state blocks).
- Every Actions run linked from the description or the author's comments, in a
  repository listed in `main_branch_run_repos`, ran a commit on that
  repository's default branch. A run Thingie can't read doesn't block; the
  approval lists it as not checked.

The approval is submitted for the exact commit Thingie evaluated, and an
approval Thingie gave an earlier commit is dismissed before it approves the new
one. When Thingie doesn't approve, it keeps one status comment on the PR saying
why, updated in place; the comment is removed once the PR is approved.

## Setup

1. Turn on automatic Copilot code review for the repository (a ruleset with
   the "Automatically request Copilot code review" rule, reviewing on push).
2. Add `.thingie/config.toml`:

   ```toml
   [approve]
   enabled = true
   max_changes = 500
   protected_paths = [".thingie/**/*", ".github/**/*", "app/billing/**"]
   ```

3. Add a workflow that runs whenever the PR or its reviews change, so Thingie
   re-decides as soon as Copilot's review lands:

   ```yaml
   # .github/workflows/thingie-approve.yml
   name: "Thingie Approve"
   on:
     pull_request:
       types: [opened, synchronize, reopened, ready_for_review, labeled, unlabeled]
     pull_request_review:
       types: [submitted, dismissed]

   concurrency:
     group: thingie-approve-${{ github.event.pull_request.number }}

   jobs:
     approve:
       runs-on: ubuntu-latest
       permissions:
         contents: read
         pull-requests: write
       steps:
         # Read the rules from the base branch, never from the PR.
         - uses: actions/checkout@v4
           with:
             ref: ${{ github.event.pull_request.base.sha }}
             sparse-checkout: .thingie
         - uses: ruby/setup-ruby@v1
           with:
             ruby-version: "3.4"
         - name: Install Thingie
           env:
             THINGIE_REF: "0.12.0"
           run: |
             git clone --quiet --depth 1 --branch "$THINGIE_REF" https://github.com/bonusly/thingie.git /tmp/thingie
             gem build /tmp/thingie/thingie.gemspec --output /tmp/thingie.gem
             gem install /tmp/thingie.gem
         - name: Approve
           env:
             GITHUB_TOKEN: ${{ github.token }}
             THINGIE_RESOLVE_TOKEN: ${{ secrets.THINGIE_RESOLVE_TOKEN }}
           run: thingie approve
   ```

   The composite action at
   [`.github/actions/thingie/action.yml`](.github/actions/thingie/action.yml)
   does the install and run steps for you when Thingie is available as a gem.

### Which token approves

Thingie approves with `GITHUB_TOKEN` first and falls back to
`THINGIE_RESOLVE_TOKEN` (a PAT) when that attempt errors. An approval from
`GITHUB_TOKEN` or a GitHub App installation token doesn't count toward
branch-protection "required approvals", and because it succeeds it never falls
through to the PAT. If Thingie's approval should satisfy required reviews, pass
the PAT of a bot user with write access as `GITHUB_TOKEN`. Reading
`approval_team` membership also needs a token with `read:org`.

## Configuration

All settings live under `[approve]` in `.thingie/config.toml`; the defaults
are in [`lib/thingie/config/default.toml`](lib/thingie/config/default.toml).

| Setting | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Nothing happens unless this is `true` |
| `dry_run` | `false` | Decide and post the result as a status comment, without approving or dismissing |
| `max_changes` | `500` | Additions plus deletions above this block |
| `skip_label` | `thingie-skip-approve` | A PR carrying this label is skipped |
| `protected_paths` | `[".thingie/**/*"]` | Globs that block when any changed file matches; setting it replaces the default |
| `approval_team` | `""` | `org/team-slug` whose members' PRs are eligible; empty means anyone |
| `approval_bots` | `[]` | Bot logins also eligible when `approval_team` is set |
| `main_branch_run_repos` | `[]` | `owner/name` repos whose linked Actions runs must come from the default branch |
| `external_checks` | `[]` | Other merge gates, listed in the approval so it's clear Thingie isn't the only one |

Tokens come from the environment (`GITHUB_TOKEN`, `THINGIE_RESOLVE_TOKEN`) or
the `--token` / `--resolve-token` flags. `~/.thingie/.env` is loaded too, for
local runs. Outside GitHub Actions, name the PR explicitly:

```bash
thingie approve --gh-repo bonusly/special_sauce --pr 123
```

Set `THINGIE_DEBUG=1` or pass `--debug` for extra logging.

## Stats logging

Thingie can emit an `approval.decided` event after each decision, so you can
track the auto-approve rate and block reasons in a dashboard. It's off unless
`stats.enabled` is `true` **and** at least one `[[stats.sinks]]` is configured.

Each event is one JSON object per line: `event`, `timestamp` (ISO 8601),
`thingie_version`, `action` (`approve`, `block` or `skip`), `reasons`, `repo`,
`pr_number` and `dry_run`, plus any constant `[stats.tags]`.

```toml
[stats]
enabled = true

[stats.tags]
team = "platform"

[[stats.sinks]]
type = "jsonl"                      # append to a file, or "stdout" / "stderr"
path = "log/thingie-stats.jsonl"

[[stats.sinks]]
type = "command"                    # pipe each event to a command's stdin
command = "my-stats-shipper"
```

Sink failures are fail-open: a failing sink is warned about and skipped. Any
gem can add a sink type with `Thingie::Stats.register_sink`; set the entry's
`require` to load it first. A sink class implements `initialize(config:, root:)`
and `emit(event)`.

## Development

```bash
bundle install
bundle exec rake   # RuboCop + RSpec
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
