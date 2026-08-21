# Thingie: Ruby (but mostly Rails) Review Thing

Thingie is an opinionated but helpful and flexible AI code review tool for Ruby and Rails projects. It is heavily inspired by [Gito](https://github.com/Nayjest/Gito) and brings the same LLM-driven review workflow to Ruby codebases, with extra context pulled from the Ruby LSP.

## Features

- AI-powered code review via any OpenAI-compatible LLM (powered by [ruby_llm](https://github.com/crmne/ruby_llm)).
- Ruby and Rails-aware review prompts out of the box.
- Reads project skills and rules from configurable directories (defaults to `.agents`, `.claude`, and `.cursor`).
- Configurable request timeouts, retries, and logging to fail fast on unreachable providers.
- Pulls extra context from language servers (LSP) during review — ruby-lsp first, any LSP via config. (Run static analyzers like RuboCop as a separate step.)
- Cuts false positives with a **critic pass** (`[verify]`): every surviving finding is re-checked by a fresh, skeptical LLM call before it's reported.
- Runs as a GitHub Action composite action, posting feedback as precise PR comments and (with a suitable token) resolving stale review threads automatically.

## Quickstart (after release)

Add to your repository:

```yaml
# .github/workflows/thingie-review.yml
name: "Thingie Review"
on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: Bonusly/rubyrt/.github/actions/thingie@v1
        with:
          api_key: ${{ secrets.LLM_API_KEY }}
          provider: openrouter
          model: moonshotai/kimi-k2.6
```

### Ruby version and run command

- **`ruby_version`** — Ruby the action installs to run Thingie. Defaults to `3.4`.
- **`thingie_command`** — how the CLI is invoked. Defaults to `thingie`. Set it to `bundle exec thingie`, `direnv exec . thingie`, etc. when your environment needs it.
- **`thingie_version`** — gem version to install (`local` builds from the checked-out repo). Set to `skip` to install nothing when `thingie_command` already provides Thingie (e.g. it's in your Gemfile).

```yaml
      - uses: Bonusly/rubyrt/.github/actions/thingie@v1
        with:
          api_key: ${{ secrets.LLM_API_KEY }}
          ruby_version: "4.0"
          thingie_command: bundle exec thingie
          thingie_version: skip   # thingie comes from the project's Gemfile
```

### Full working example (the workflow this repo runs)

Thingie reviews its own pull requests. Below is the actual
`.github/workflows/thingie-review.yml` from this repo — copy it as a known-good
starting point. It mints a GitHub App token when one is configured (so comments
post under the app's name) and otherwise falls back to the default token.

```yaml
# .github/workflows/thingie-review.yml
name: "Thingie Review"

on:
  pull_request:
    types: [opened, synchronize, reopened]
  workflow_dispatch:
    inputs:
      pr_number:
        description: "Pull Request number"
        required: true

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      # Mint an app installation token so review comments post under the app's
      # name/avatar. Skipped (falls back to GITHUB_TOKEN) when the app isn't set up.
      - uses: actions/create-github-app-token@v3
        id: app_token
        if: ${{ vars.THINGIE_APP_ID != '' }}
        with:
          client-id: ${{ vars.THINGIE_APP_ID }}
          private-key: ${{ secrets.THINGIE_APP_PRIVATE_KEY }}
      - name: Run Thingie review
        uses: Bonusly/rubyrt/.github/actions/thingie@v1
        with:
          api_key: ${{ secrets.LLM_API_KEY }}
          model: ${{ vars.LLM_MODEL }}
          provider: ${{ vars.LLM_PROVIDER }}
          # Post as the app when configured, otherwise as github-actions.
          github_token: ${{ steps.app_token.outputs.token || github.token }}
          # PAT (user token) with pull-requests write so stale review threads can
          # be auto-resolved — GITHUB_TOKEN and App tokens cannot. Skipped if unset.
          resolve_token: ${{ secrets.THINGIE_RESOLVE_TOKEN }}
```

Model and provider come from repo **variables** (`vars.LLM_MODEL`,
`vars.LLM_PROVIDER`) so you can change them without editing the workflow. This
repo runs the review on OpenRouter and re-checks findings with a stronger model
in the critic pass — see [The critic pass](#the-critic-pass-reducing-false-positives).

The action referenced above is the composite action at
[`.github/actions/thingie/action.yml`](.github/actions/thingie/action.yml); it
installs Ruby, installs Thingie, computes the base ref (unshallowing as needed so
merge-base is correct), runs the review, posts the comment, and uploads the JSON
and Markdown reports as artifacts.

### Required secrets and permissions

- `secrets.LLM_API_KEY`: Your LLM provider API key.
- `secrets.GITHUB_TOKEN` is provided automatically by GitHub Actions. It must have at least `pull-requests: write` permission (set in the workflow `permissions` block) so Thingie can post review comments.
- Want comments to post under a custom name and avatar instead of "github-actions"? See **Posting as a GitHub App** below.
- Resolving stale review threads needs an **extra** token — see **Resolving stale review threads** below. The default `GITHUB_TOKEN` cannot do it.

### Posting as a GitHub App (custom name and avatar)

By default Thingie posts as **github-actions[bot]** (the workflow `GITHUB_TOKEN`). To post under your own bot name and avatar, authenticate with a **GitHub App installation token** and pass it as the action's `github_token` input — review comments then appear as **YourApp[bot]**.

1. Create the app: **Settings → Developer settings → GitHub Apps → New GitHub App** (under your org or account). Give it the name and avatar you want to see on comments.
   - **Repository permissions → Pull requests: Read and write.** (No webhook needed — uncheck **Active**.)
2. **Generate a private key** and note the **App ID**.
3. **Install the app** on the repositories that run Thingie.
4. Store the **App ID** as a variable (e.g. `vars.THINGIE_APP_ID`) and the private key as a secret (e.g. `secrets.THINGIE_APP_PRIVATE_KEY`).
5. Mint an installation token with [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token) and pass it as `github_token`:

```yaml
jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/create-github-app-token@v2
        id: app_token
        with:
          app-id: ${{ vars.THINGIE_APP_ID }}
          private-key: ${{ secrets.THINGIE_APP_PRIVATE_KEY }}
      - uses: Bonusly/rubyrt/.github/actions/thingie@v1
        with:
          api_key: ${{ secrets.LLM_API_KEY }}
          github_token: ${{ steps.app_token.outputs.token }}   # post as the app
          resolve_token: ${{ secrets.THINGIE_RESOLVE_TOKEN }}    # resolve threads (PAT — see below)
```

> The app installation token posts comments fine, but **cannot resolve review threads** (`resolveReviewThread` rejects server-to-server tokens). If you also want stale threads auto-resolved, pair it with a user PAT in `resolve_token` as shown — see the next section.

### Resolving stale review threads

When Thingie re-reviews a PR, it can mark its earlier threads as resolved once the issue is fixed or the line is outdated. This uses the GraphQL `resolveReviewThread` mutation, which **requires a user-to-server token (a personal access token).**

> **The default `GITHUB_TOKEN` cannot do this, and neither can a GitHub App.** Both are *server-to-server* tokens, and `resolveReviewThread` returns `Resource not accessible by integration` for them even with `pull-requests: write` — including the installation token from `actions/create-github-app-token`. Only a user PAT works.

To enable auto-resolving, create a PAT and pass it via the `resolve_token` action input (or the `THINGIE_RESOLVE_TOKEN` env var / `--resolve-token` flag for the `github-comment` CLI). If you don't set one, Thingie skips resolving and still posts the new review.

1. Create a token as a user with write access to the repo:
   - **Classic PAT** with the `repo` scope (**recommended** — reliably works for `resolveReviewThread`). **Settings → Developer settings → Personal access tokens → Tokens (classic)**. If your org enforces SSO, click **Configure SSO** on the token and authorize it for the org.
   - **Fine-grained PATs are not recommended here.** Even with **Pull requests: Read and write** they often fail `resolveReviewThread` with `Resource not accessible by personal access token` — and for an **org** repo the write permission stays **read-only until an org owner approves it**, so the fetch succeeds but resolving fails. If you must use one, get it org-approved and expect to troubleshoot.
2. Store it as a repository (or org) secret, e.g. `secrets.THINGIE_RESOLVE_TOKEN`.
3. Pass it to the action:

```yaml
jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: Bonusly/rubyrt/.github/actions/thingie@v1
        with:
          api_key: ${{ secrets.LLM_API_KEY }}
          provider: openrouter
          model: moonshotai/kimi-k2.6
          resolve_token: ${{ secrets.THINGIE_RESOLVE_TOKEN }}
```

Threads are resolved as whichever user owns the PAT. (A machine/bot user account is a good fit if you don't want resolutions attributed to a person.)

### Auto-approving PRs

Thingie can submit an **Approve** review when a PR is clean enough. It's **off by default** — enable it under `[approve]` in `.thingie/config.toml`:

```toml
[approve]
enabled = true
max_changes = 500          # additions + deletions ceiling; blocks approval if GitHub doesn't report the size
max_severity = 3           # BLOCK line: issues at/below this severity number (1=Critical) block approval — independent from post_process.max_severity (the SHOW line), see "Filtering findings" below
skip_label = "thingie-skip-approve"
approval_team = "bonusly/pr-auto-approval"  # only auto-approve PRs whose author is on this GitHub team (needs read:org)
protected_paths = ["app/billing/**", "config/secrets.yml"]  # globs that block approval when changed
dry_run = false            # evaluate and log the decision without approving/dismissing
```

A PR is approved only when **all** of these hold:

- It isn't a draft and doesn't carry the `skip_label`.
- Its author is a member of `approve.approval_team`, when that option is set (a non-member is skipped, not blocked, so a human's approval is left intact). Reading team membership needs a `read:org` token — set `THINGIE_RESOLVE_TOKEN` to a PAT with that scope.
- It doesn't modify `.thingie/config.toml` — a PR can't weaken the approval rules and wave itself through.
- No changed file matches a `protected_paths` glob — e.g. billing code or sensitive config you always want a human to review.
- Total changes are within `max_changes` (an unknown size fails safe and blocks approval).
- This run produced no findings at or above `max_severity`.
- No Thingie findings at or above `max_severity` are still unresolved.
- No human reviewer's current review is `CHANGES_REQUESTED` (a later dismissal or approval by that reviewer clears it). Thingie never waves through a change a human has pushed back on; an undeterminable review state fails safe and blocks.
- Every resolved Thingie finding at or above `max_severity` was resolved by someone who is **neither the PR author nor a contributor** to the PR — an author can't clear their own findings to earn an approval.

When Thingie does **not** approve — a rule failed (block) or the run was skipped — it posts a single status comment on the PR explaining why, and keeps that comment updated in place on re-runs (it doesn't stack a new comment each push). Once the PR qualifies and is approved, that status comment is removed.

Re-runs are idempotent: Thingie won't stack a second approval on a head commit it already approved, and it **dismisses** its earlier approval if a later push stops meeting the rules. It also dismisses any approval left over from a **previous commit** before approving a new head, so an approval never outlives the exact commit it was granted for. With `dry_run = true` it takes no approve/dismiss action, but posts the result as a status comment marked `Dry run — no approval action was taken.` A successful dry run includes the same passed-checks details that an approval would have contained, making it useful for rollout.

> **Close the re-review window with branch protection.** Thingie only runs *as* the push-triggered workflow, so between a new push and the re-review finishing, an approval granted for the previous commit still counts unless GitHub dismisses it. Enable branch protection's **"Dismiss stale pull request approvals when new commits are pushed"** so a new commit invalidates the prior approval instantly; Thingie then re-approves only if the new commit still passes.

The approval comment lists the checks that passed and a collapsed **Thingie details** section (Thingie version and the review model). If you set `approve.external_checks` (e.g. `["Security review pass", "Full test suite"]`), those are listed under **Other checks that must pass before merge** — checks Thingie does not evaluate but that still gate merge, so it's clear Thingie's approval isn't the only gate (they don't affect Thingie's decision).

When an LLM key is available in the `github-comment` step, it also adds an informational **risk assessment**. Rather than restating the rules, the LLM looks at the actual code diff and gives an honest Low/Medium risk read focused on regressions, downtime, and security impact, with a short reason that justifies the approval. The risk level never affects the decision — the deterministic rules above do — and the section is simply omitted if no LLM client is configured or the call fails.

The approval needs the workflow's `pull-requests: write` permission (already required for comments). The risk assessment additionally needs an LLM key (`LLM_API_KEY`) available to the `github-comment` step; without it the approval still posts, just without that section. Thingie tries the approval with the main `github_token` first, then falls back to the `resolve_token` PAT if that attempt fails.

> **Heads up on which token approves.** An approval submitted by `GITHUB_TOKEN` (or a GitHub App installation token) does **not** count toward branch-protection "required approvals", and the fallback only triggers when the first attempt *errors* — a non-counting approval from `GITHUB_TOKEN` succeeds and won't fall through to the PAT. If you need the approval to satisfy required reviewers, run Thingie with the PAT as its main `github_token` (or as a bot user) so the counting identity is the one that approves.

> **Limitation.** "Contributor" is determined from commit author/committer GitHub logins, so a `Co-authored-by:` trailer doesn't count as having committed. If a thread's resolver can't be determined (e.g. a deleted account), Thingie fails safe and does not approve.

### Configuration options

Thingie reads configuration from layers (later layers override earlier ones):

1. `lib/thingie/config/default.toml` bundled with the gem.
2. `.thingie/config.toml` in your project root.
3. `~/.thingie/.env` (loaded into your environment).
4. Environment variables.
5. CLI flags.

Key settings:

| Setting | Default | Config key | Environment variable | CLI flag |
|---|---|---|---|---|
| LLM provider | `openai` | `provider` | `LLM_PROVIDER` | `-p`, `--provider` |
| LLM model | `gpt-4o` | `model` | `LLM_MODEL` | `-m`, `--model` |
| API key | — | `llm_api_key` | `LLM_API_KEY` | — |
| API base URL | provider default | `llm_api_base` | `LLM_API_BASE` | — |
| Request timeout (seconds) | `120` | `request_timeout` | `LLM_REQUEST_TIMEOUT` | — |
| Retries | `3` | `retries` | `LLM_RETRIES` | — |
| Log file | stdout | `log_file` | `THINGIE_LOG_FILE` | — |
| Log level | `info` | `log_level` | `THINGIE_LOG_LEVEL` | — |
| Max concurrent file reviews | `10` | `max_concurrent_tasks` | `MAX_CONCURRENT_TASKS` | — |
| Confidence threshold (keep if ≤) | `1` | `post_process.max_confidence` | — | — |
| Severity threshold (keep if ≤) | `3` | `post_process.max_severity` | — | — |
| Critic pass enabled | `true` | `verify.enabled` | — | — |
| Critic pass model | review model | `verify.model` | — | — |
| Auto-approve PRs | `false` | `approve.enabled` | — | — |
| Auto-approve change limit | `500` | `approve.max_changes` | — | — |
| Auto-approve severity gate | `3` | `approve.max_severity` | — | — |
| Auto-approve skip label | `thingie-skip-approve` | `approve.skip_label` | — | — |
| Auto-approve protected paths | `[".thingie/**/*"]` | `approve.protected_paths` | — | — |
| Auto-approve team gate | `""` (disabled) | `approve.approval_team` | — | — |
| Auto-approve dry run | `false` | `approve.dry_run` | — | — |
| Skill directories | `.agents`, `.claude`, `.cursor` | `skill_directories` | — | — |
| Language servers | none | `lsp.<name>` | — | — |
| Stats logging | `false` | `stats.enabled` | — | — |

Supported providers match whatever RubyLLM supports, including `openai`, `anthropic`, `gemini`, `ollama`, `deepseek`, `openrouter`, `mistral`, `perplexity`, `xai`, `azure`, `bedrock`, `vertexai`, and `gpustack`.

Example `.thingie/config.toml`:

```toml
provider = "openrouter"
model = "moonshotai/kimi-k2.6"
request_timeout = 60
log_file = "log/thingie.log"
log_level = "debug"

# Customize which directories are scanned for skill fragments
skill_directories = [".agents", ".github"]

# Only keep the most-confident findings (1) up to medium severity (3).
[post_process]
max_confidence = 1
max_severity = 3

# Re-check every surviving finding with a stronger model before reporting it.
[verify]
enabled = true
model = "anthropic/claude-opus-4.8"

# Give the LLM access to a language server for extra code context.
[lsp.ruby]
command = ["ruby-lsp"]
extensions = [".rb", ".rake"]

# Emit machine-readable stats events after each review and auto-approval.
[stats]
enabled = true
[[stats.sinks]]
type = "jsonl"
path = "log/thingie-stats.jsonl"
```

### Skills

Thingie automatically discovers markdown files (`.md`) in skill directories and injects them as additional rules in every review prompt. By default it scans `.agents/`, `.claude/`, and `.cursor/` in the project root. Override this with the `skill_directories` config key.

### The critic pass (reducing false positives)

The biggest source of noise in AI review is confident-but-wrong findings —
claims that simply aren't true about the code. Tightening the confidence and
severity thresholds only filters by the model's *self-reported* confidence,
which it routinely over-states.

The `[verify]` critic pass attacks this directly. After the normal review and
threshold filtering, each surviving finding gets a second, **fresh** LLM call
framed adversarially: *"try to refute this; uphold it only if you can point to
the lines that make it true; when uncertain, reject."* The critic has the diff,
the full file, and (if configured) the LSP symbol tool, so it can confirm API
and method claims instead of trusting them. Findings it can't uphold are
dropped.

```toml
[verify]
enabled = true                      # on by default; set false to skip the pass
model = "anthropic/claude-opus-4.8" # optional: re-check on a stronger model
```

- **`verify.enabled`** — turn the critic pass on or off. Default `true`.
- **`verify.model`** — run the critic on a different (usually stronger) model
  than the review, using the **same provider and API key**. Leave it unset to
  reuse the review model. With OpenRouter the model slug is provider-prefixed
  (e.g. `anthropic/claude-opus-4.8`), so one key covers both the cheap review
  model and the strong critic.

Because the critic runs only on findings that survived filtering — not on every
file — its cost scales with the number of findings, not the size of the diff. It
also **fails open**: if a critic call errors or returns an unparseable verdict,
the finding is kept and a processing warning is recorded, so a broken critic
never silently swallows a real bug.

The critic can also **correct a miscalibrated severity or confidence grade**
instead of only upholding/rejecting a finding outright — e.g. downgrade an
overstated "Critical" cosmetic nit, or upgrade an understated security issue.
Both the review and critic prompts are given the same severity/confidence
scale and the current `post_process`/`approve` thresholds (see below), so the
model reasons about real consequences rather than abstract labels. An override
only affects this run's final severity/confidence (and therefore whether the
finding blocks auto-approval, below) — it does not re-run the `post_process`
filter that already let the finding through to the critic in the first place.

### Filtering findings (`post_process`)

The model scores every finding on a 1–4 **severity** scale (1 = Critical) and a
1–4 **confidence** scale (1 = highest). `post_process` is the **SHOW line**: it
drops anything above your thresholds *before* the critic pass runs, controlling
whether a finding is surfaced to maintainers as a PR comment at all:

```toml
[post_process]
max_confidence = 1   # keep only the model's highest-confidence findings
max_severity = 3     # keep Critical/High/Medium, drop Low
```

Lower numbers are stricter. An omitted threshold means "no limit". This is a
cheap first filter; the critic pass is the precision filter on top of it.

This is independent from `approve.max_severity` (the **BLOCK line**, see
[Auto-approving PRs](#auto-approving-prs)) — a finding can be shown as a
comment without blocking auto-approval, e.g. `post_process.max_severity = 3`
but `approve.max_severity = 2`.

### Language servers (LSP)

When you configure a language server, Thingie exposes a symbol-lookup tool to the
LLM during both review and verification. The model uses it to confirm that a
class, method, or constant actually exists (and how a third-party API is shaped)
before reporting an "undefined" or "misused API" issue — a major source of
hallucinated findings.

```toml
# Each [lsp.<name>] entry is launched in the reviewed project's root, so use
# that project's own LSP binary. Add more languages with more entries.
[lsp.ruby]
command = ["ruby-lsp"]
extensions = [".rb", ".rake"]
```

A server is only started when the changeset contains a file whose extension
matches one of its `extensions`, so unrelated reviews don't pay the startup
cost. LSP is disabled entirely when no `[lsp.*]` entry is configured.

### Logging

Set `log_file` to a file path to persist RubyLLM request logs for debugging. Set `log_level` to `debug` to see full request and response bodies. Valid levels are `debug`, `info`, `warn`, `error`, and `fatal`.

### Stats logging

Thingie can emit machine-readable stats events after each review and auto-approval decision, so you can build dashboards (Datadog, Logstash, Fluentd, Vector, …) that track review volume, finding rates, LLM token usage, and the auto-approve rate. It's **off by default** — nothing is emitted unless `stats.enabled` is `true` **and** at least one `[[stats.sinks]]` destination is configured. There is no environment-variable toggle (enable it in config, the same as `[approve]` and `[verify]`).

Two events are emitted:

- **`review.completed`** — after a successful `thingie review` run. Carries the commit SHA, branch, model, files reviewed, total issues, issue counts by severity and by tag, the review duration in milliseconds, and accumulated LLM usage (input/output/cache tokens and cost).
- **`approval.decided`** — after the auto-approval step of `thingie github-comment`. Carries the action (`approve`, `block`, or `skip`), the block reasons (empty for `approve`/`skip`), the `repo` (`owner/repo`), PR number, and whether it was a dry run.

Every event is a single JSON object on one line, with a stable schema: `event`, `timestamp` (ISO 8601), `thingie_version`, and the event-specific fields. GitHub identity (`repo`, `pr_number`) is enriched from the GitHub Actions environment when available; explicit fields on the `approval.decided` event override the env-derived ones. Constant `tags` from `[stats.tags]` are copied into every event when set.

Built-in sink types:

- **`jsonl`** — append one JSON object per event to a file, or to `stdout`/`stderr`. Relative paths are resolved against the project root; parent directories are created. The Datadog Agent tails JSON-lines files natively; Logstash/Fluentd/Vector ingest them with a `json` codec — no extra gems required.
- **`command`** — pipe one JSON line per event to an external command's stdin (e.g. `tee -a /var/log/thingie.jsonl` or a stats shipper you already run). On any failure (bad command, dead pipe) the sink warns once and disables itself for the rest of the run — it never raises into the pipeline.

```toml
[stats]
enabled = true

# Constant key/value pairs copied into every event under "tags".
[stats.tags]
team = "platform"
environment = "production"

# Destinations — one [[stats.sinks]] block each.
[[stats.sinks]]
type = "jsonl"
path = "log/thingie-stats.jsonl"   # or "stdout" / "stderr"

[[stats.sinks]]
type = "command"
command = "my-stats-shipper"
```

Sink failures are **fail-open**: a stats outage never fails a review. A failing sink is warned about and skipped; the others still receive the event.

#### Custom sink plugins

Any gem can register an additional sink type via `Thingie::Stats.register_sink`. A sink class implements `initialize(config:, root:)` (raise `ArgumentError` on a missing required key) and `emit(event)` (serialize/ship the fully-formed, string-keyed event Hash). Set the entry's `require` to load the gem before the type is looked up:

```toml
[[stats.sinks]]
type = "my_custom_sink"
require = "my_thingie_sink_gem"   # required before the type is looked up
```

The two key risk indicators that motivated this feature — **auto-approve rate** and **block-reason histogram** — are directly computable from `approval.decided` events. Post-merge indicators (revert rate, human override after approve) happen after merge and can only be computed downstream, so every event carries stable join keys (`repo`, `pr_number`, `commit_sha`) that let a downstream pipeline correlate them with merge and revert events.

### Structured output

Thingie uses [structured output](https://rubyllm.com/available-models/#structured-output-469) to ensure the LLM returns valid JSON. Not all models support this feature; see the [RubyLLM available models page](https://rubyllm.com/available-models/#structured-output-469) for a list of compatible models. For models that don't support structured output, Thingie falls back to parsing the response as JSON from the prompt instructions.

## Development

```bash
bundle install
bundle exec rake
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
