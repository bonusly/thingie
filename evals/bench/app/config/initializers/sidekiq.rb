redis_config = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1") }

Sidekiq.configure_server do |config|
  config.redis = redis_config
  config.logger.level = Rails.env.production? ? Logger::INFO : Logger::DEBUG

  schedule_file = Rails.root.join("config/sidekiq.yml")
  schedule = YAML.safe_load_file(schedule_file, permitted_classes: [Symbol]).fetch(:schedule, {})
  Sidekiq::Cron::Job.load_from_hash!(schedule) if schedule.any?
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end

Sidekiq.strict_args!
