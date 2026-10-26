module Search
  class Error < StandardError; end

  class RouterMissing < Error
    def initialize(path)
      super("router file not found at #{path}")
    end
  end

  class RouterEmpty < Error
    def initialize(path)
      super("no routes could be parsed from #{path}")
    end
  end

  class NotConnected < Error
    attr_reader :provider

    def initialize(provider)
      @provider = provider
      super(I18n.t("search.errors.not_connected", provider: I18n.t("connectors.providers.#{provider}", default: provider)))
    end
  end

  class PageLimitExceeded < Error
    def initialize(pages, max:)
      super(I18n.t("search.errors.page_limit", pages: pages, max: max))
    end
  end
end
