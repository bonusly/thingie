# Tasker

Multi-tenant team task app. Companies hold users via memberships, and users
keep lists of tasks with assignees, due dates, labels, attachments and
comments. Each member has a weekly points budget they can attach to tasks as
rewards; draft tasks reserve points until they are sent.

## Stack

- Rails API (MongoDB via Mongoid)
- Sidekiq for background jobs
- Redis for locks and job queues
- Blueprinter for serialization
- RSpec with FactoryBot

## Running

```
bin/rails server
bundle exec sidekiq -C config/sidekiq.yml
bin/rspec
```

Connectors (GitHub, Slack, Linear) need credentials in `.env`; see
`config/initializers/connectors.rb` for the variable names.

## Connected search

`GET /api/v1/search/connected` searches the last 14 days of activity across
the caller's connected accounts. Each provider is a tool under
`app/lib/search/tools/` that pages through its API at most 5 pages per call
and returns a `next_cursor`; pass it back as `cursor` to load more. The same queries back `Connectors::Jobs::SyncAccountJob`, which runs
every registered query for an account and advances `last_synced_at`.
