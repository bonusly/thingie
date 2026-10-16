module Features
  class Disabled < StandardError
    def initialize(flag)
      super("#{flag} is not enabled")
    end
  end

  def self.enabled?(flag, subject)
    rule = rules.fetch(flag.to_s, nil)
    return false if rule.nil?
    return true if rule["everyone"] == true

    case subject
    when Company then Array(rule["companies"]).include?(subject.slug)
    when User then Array(rule["users"]).include?(subject.email)
    else false
    end
  end

  def self.rules
    (Rails.application.config.x.features.rules || {}).to_h.deep_stringify_keys
  end
end
