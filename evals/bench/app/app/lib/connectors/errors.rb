module Connectors
  class Error < StandardError; end

  class InvalidInput < Error
    attr_reader :details

    def initialize(details)
      @details = details
      super("invalid input: #{details.to_h}")
    end
  end

  class Unauthorized < Error
    def initialize(provider)
      super("#{provider} rejected the access token")
    end
  end

  class RateLimited < Error
    attr_reader :retry_after

    def initialize(provider, retry_after: nil)
      @retry_after = retry_after
      super("#{provider} rate limit reached")
    end
  end

  class UnknownProvider < Error
    def initialize(provider)
      super("no connector registered for #{provider.inspect}")
    end
  end
end
