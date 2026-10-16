module FeatureHelpers
  def enable_feature(flag, **rule)
    rule = { everyone: true } if rule.empty?
    Rails.application.config.x.features.rules = Features.rules.merge(flag.to_s => rule.deep_stringify_keys)
  end
end

RSpec.configure do |config|
  config.include FeatureHelpers

  config.around do |example|
    original = Rails.application.config.x.features.rules
    example.run
  ensure
    Rails.application.config.x.features.rules = original
  end
end
