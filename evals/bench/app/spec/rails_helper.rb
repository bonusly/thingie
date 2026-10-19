require "spec_helper"

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "sidekiq/testing"
require "webmock/rspec"

Rails.root.glob("spec/support/**/*.rb").sort.each { |file| require file }

Sidekiq::Testing.fake!
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
  config.include ApiHelpers, type: :request

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.before(:suite) do
    DatabaseCleaner[:mongoid].strategy = :deletion
    DatabaseCleaner[:mongoid].clean_with(:deletion)
  end

  config.around do |example|
    DatabaseCleaner[:mongoid].cleaning { example.run }
  end

  config.before do
    Sidekiq::Worker.clear_all
    AppRedis.with(&:flushdb)
    ActionMailer::Base.deliveries.clear
  end
end
