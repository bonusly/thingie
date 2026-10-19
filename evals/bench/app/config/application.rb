ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup"
require "bootsnap/setup"

require "rails"
require "active_model/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module Tasker
  class Application < Rails::Application
    config.load_defaults 7.2
    config.api_only = true
    config.time_zone = "UTC"
    config.eager_load_paths << Rails.root.join("app/lib")
    config.autoload_lib(ignore: %w[tasks])
    Rails.autoloaders.main.ignore(Rails.root.join("app/lib/*/errors.rb"))
    config.to_prepare do
      Dir[Rails.root.join("app/lib/*/errors.rb")].sort.each { |file| load file }
    end
    config.i18n.load_path += Dir[Rails.root.join("config/locales/**/*.yml")]
    config.i18n.available_locales = %i[en]
    config.active_job.queue_adapter = :sidekiq
    config.generators.system_tests = nil
    config.generators do |g|
      g.orm :mongoid
      g.test_framework :rspec, fixture: false
    end
    config.x.points.default_weekly_budget = 100
    config.x.share_links.default_ttl = 30.days
    config.x.connectors.max_pages_per_call = 5
  end
end
