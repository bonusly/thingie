# Let the search tools page through GitHub, Slack and Linear results

Adds a connected search endpoint, `GET /api/v1/search/connected`, backed by one tool per
provider under `app/lib/search/tools/`. Each tool wraps the matching connector query, which
now accepts `since_days`, `pages` and `cursor` and returns `next_cursor` so a caller (the
assistant or the UI) can page through results instead of getting the first page only.
`PageLimit` still caps a single call at 5 pages; `LookBack` learned `since_days` and exposes
the window floor.

Along the way:

- GitHub search results now page from `total_count` because the search API's Link header
  is unreliable past page 10.
- Linear team filtering moved server-side into the GraphQL filter.
- Slack messages with a thread now include their replies.
- `SyncAccountJob` computes one watermark per run, passes it to every query, retries
  unexpected errors through Sidekiq (`retry: 5`) and records the error when retries run out.
  Cursors are per-call tokens, so the job no longer stores one on the account.

## Testing

- Specs for the three tools, the connected search query, the endpoint, `LookBack`,
  `PageLimit`, every connector query and the sync job.
- Manually: connected GitHub and Slack on dev, searched with `since_days=3`, paged with the
  returned cursors until `truncated` was false, then ran `rake connectors:sync` and checked
  `last_synced_at` moved.

## Files

40 files at the final push (26 modified, 14 added); a first push with 40 files, 7 of them different from the final push.
The diff of each push against the fixture app: `git -C evals/bench/tmp/paged-connectors diff pr-base pr-final-push` after a run, or build it with `bundle exec ruby -e 'require "./evals/bench/lib/bench"; Bench::Case.load("paged-connectors").build'`.

- modified `README.md`
- modified `app/controllers/api/v1/search_controller.rb`
- modified `app/controllers/concerns/handles_errors.rb`
- modified `app/lib/connectors/github/client.rb`
- modified `app/lib/connectors/github/queries/list_issues.rb`
- modified `app/lib/connectors/github/queries/list_pull_requests.rb`
- modified `app/lib/connectors/jobs/sync_account_job.rb`
- modified `app/lib/connectors/linear/client.rb`
- modified `app/lib/connectors/linear/queries/list_issues.rb`
- modified `app/lib/connectors/linear/queries/list_projects.rb`
- modified `app/lib/connectors/services/look_back.rb`
- modified `app/lib/connectors/services/page_limit.rb`
- modified `app/lib/connectors/slack/client.rb`
- modified `app/lib/connectors/slack/queries/list_messages.rb`
- modified `app/lib/search/errors.rb`
- added `app/lib/search/queries/connected_search.rb`
- added `app/lib/search/tools/base.rb`
- added `app/lib/search/tools/github_search.rb`
- added `app/lib/search/tools/linear_search.rb`
- added `app/lib/search/tools/registry.rb`
- added `app/lib/search/tools/slack_search.rb`
- modified `app/models/connector_account.rb`
- added `config/locales/en/search.yml`
- modified `config/routes.rb`
- modified `spec/factories/connector_accounts.rb`
- modified `spec/lib/connectors/github/queries/list_issues_spec.rb`
- added `spec/lib/connectors/github/queries/list_pull_requests_spec.rb`
- modified `spec/lib/connectors/jobs/sync_account_job_spec.rb`
- modified `spec/lib/connectors/linear/queries/list_issues_spec.rb`
- added `spec/lib/connectors/linear/queries/list_projects_spec.rb`
- modified `spec/lib/connectors/services/look_back_spec.rb`
- modified `spec/lib/connectors/services/page_limit_spec.rb`
- modified `spec/lib/connectors/slack/queries/list_messages_spec.rb`
- added `spec/lib/search/queries/connected_search_spec.rb`
- added `spec/lib/search/tools/github_search_spec.rb`
- added `spec/lib/search/tools/linear_search_spec.rb`
- added `spec/lib/search/tools/slack_search_spec.rb`
- modified `spec/models/connector_account_spec.rb`
- added `spec/requests/api/v1/search_spec.rb`
- modified `spec/support/shared_contexts.rb`


## Planted defects (real)

| Defect | File | Push | | Mechanism |
|---|---|---|---|---|
| Sync advances last_synced_at even when the page cap cut the walk short | `app/lib/connectors/jobs/sync_account_job.rb` | both |  | perform discards result.next_cursor and calls account.touch_synced!(synced_at: started_at) (early: touch_synced!) regardless of whether pages_fetched hit PageLimit.max_pages; the next run's LookBack starts at last_synced_at - 5 minutes, so items older than the last fetched page but newer than the previous watermark are never imported. Any account with more than 5 pages (250 GitHub issues, 500 Slack messages) in a window silently loses the rest. Real: data loss on the sync path every run. |
| since_days is capped at 365 days, not at the 14-day window the product promises | `app/lib/connectors/services/look_back.rb` | both |  | LookBack#call returns now - since_days.clamp(1, MAX_SINCE_DAYS).days without taking [.., floor].max, and Search::Tools::Base passes a caller-supplied since_days straight through, so GET /api/v1/search/connected?since_days=365 (or a model call) reads a year of history while config/locales/en/search.yml and the tool descriptions promise 14 days. Real: contract violation reachable from the public endpoint. |
| One cursor is reused across providers, so Slack's cursor is sent to GitHub | `app/lib/search/queries/connected_search.rb` | first |  | early ConnectedSearch takes a single cursor and passes it to every tool in Registry.for(providers); next_cursor is whichever provider's came last, so the second page of a multi-provider search sends Slack's opaque cursor to GitHub's page-number query (to_i => 0 => page 1 again) and vice versa. Head keys cursors by provider (cursors[tool.provider], next_cursors hash). Fixed at head. |
| Watermark comes from Date.today and is recomputed per query, shifting across midnight | `app/lib/connectors/jobs/sync_account_job.rb` | first |  | early perform calls updated_after for every query/scope, which returns (Date.today - 14).in_time_zone; a run that spans midnight (Slack accounts walk one query per channel) uses a later watermark for the later channels and drops a day of records, and Date.today ignores the app time zone. Head computes since once from LookBack before the walk with now: started_at. Fixed at head. |

`push` says where the defect exists: `first` means the author fixed it before the final push (scored only at the first push), `both` means it is still there at the final push, `final` means the final push introduced it.

## Nit bait

| Finding | File | Push | Kind | Why a reviewer would merge anyway |
|---|---|---|---|---|
| Page-limit check runs before the connection check | `app/lib/search/tools/base.rb` | both | messaging | Base#call raises PageLimitExceeded before NotConnected, so a user without a connected account who passes pages: 9 is told 'At most 5 pages' instead of 'GitHub is not connected'. Behaviour is still a refusal either way; wording only. |
| Linear cursor is not tied to the filter it was issued under | `app/lib/connectors/linear/queries/list_issues.rb` | both | latent edge case | team_key is now part of the GraphQL filter, and the endCursor Linear returns is only valid for that filter, but the query accepts any cursor with any team_key. No caller changes team_key between pages today (ConnectedSearch and LinearSearch pass the same options each call), so this is latent. |
| Exact multiple of per_page triggers one extra empty search call | `app/lib/connectors/github/client.rb` | both | performance | pull_requests computes next_page with page_number * per_page <= total_count, so when total_count is exactly 50 or 100 the walk requests one more page that returns zero items before stopping. One wasted request in a rare case; should be <. |
| Thread replies are capped at 500 and never paged | `app/lib/connectors/slack/queries/list_messages.rb` | both | latent edge case | replies_for fetches conversations.replies once with limit REPLY_LIMIT (500) and no oldest, then filters by since client-side; a thread with more than 500 replies silently loses the rest and the window is only applied to what came back. Needs a 500-reply thread inside a 14-day window to matter. |
| Retries-exhausted path is untested | `spec/lib/connectors/jobs/sync_account_job_spec.rb` | both | test gap | The spec covers record-and-re-raise for unexpected errors but not the sidekiq_retries_exhausted block that records 'sync gave up'. Exercising it needs Sidekiq::Testing with raise_on_failure / the retry middleware; nice to have, not blocking. |

## Wrong bait

| Finding | File | Push | | Why it is not a bug |
|---|---|---|---|---|
| Zoned time passed to an Input declared :time | `app/lib/connectors/github/queries/list_issues.rb` | both |  | The job passes LookBack's ActiveSupport::TimeWithZone as since: to Input, which declares optional(:since).maybe(:time). Dry::Schema.Params resolves :time to the coercing params.time type, which accepts Time and TimeWithZone (is_a?(Time) is true) as well as strings; spec 'accepts a zoned time for since, as the sync job passes' shows it. Not a bug. |
| Unexpected errors look swallowed by the job | `app/lib/connectors/jobs/sync_account_job.rb` | both |  | rescue StandardError => e; account.record_error!(e.message) is followed by a bare raise, and the job has sidekiq_options retry: 5 plus a sidekiq_retries_exhausted hook, so Sidekiq retries five times and the error is recorded on the account. The spec 'records and re-raises other failures so Sidekiq retries' covers it. Not swallowed. |
| Client-supplied cursors could replay another tenant's cursor | `app/lib/search/queries/connected_search.rb` | both |  | cursors come from request params, but every tool resolves its account via ConnectorAccount.for_company(company).for_provider(provider).connected.where(user_id: user.id) and the cursor is only ever sent to that account's own API with that account's token; a cursor from another tenant is just a page token the provider interprets for the caller's own data. No cross-tenant read is possible. |
