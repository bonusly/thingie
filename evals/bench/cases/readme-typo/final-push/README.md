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
