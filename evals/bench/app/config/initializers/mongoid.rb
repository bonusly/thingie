Mongoid.configure do |config|
  config.load_configuration(
    Rails.application.config_for(:mongoid).deep_symbolize_keys
  )
end

Mongoid.raise_not_found_error = true
Mongoid.belongs_to_required_by_default = true
Mongoid.log_level = Rails.env.production? ? :info : :debug

Rails.application.config.after_initialize do
  next unless Rails.env.development? && ENV["MONGOID_CREATE_INDEXES"] == "1"

  Rails.application.eager_load!
  Mongoid.models.each(&:create_indexes)
end
