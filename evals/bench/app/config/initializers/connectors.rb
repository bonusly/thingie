Rails.application.config.x.connectors.github = {
  client_id: ENV["GITHUB_CLIENT_ID"],
  client_secret: ENV["GITHUB_CLIENT_SECRET"],
  api_base: ENV.fetch("GITHUB_API_BASE", "https://api.github.com")
}

Rails.application.config.x.connectors.slack = {
  client_id: ENV["SLACK_CLIENT_ID"],
  client_secret: ENV["SLACK_CLIENT_SECRET"],
  api_base: ENV.fetch("SLACK_API_BASE", "https://slack.com/api")
}

Rails.application.config.x.connectors.linear = {
  client_id: ENV["LINEAR_CLIENT_ID"],
  client_secret: ENV["LINEAR_CLIENT_SECRET"],
  api_base: ENV.fetch("LINEAR_API_BASE", "https://api.linear.app/graphql")
}

Lockbox.master_key = ENV.fetch("LOCKBOX_MASTER_KEY") { Lockbox.generate_key if Rails.env.local? }
