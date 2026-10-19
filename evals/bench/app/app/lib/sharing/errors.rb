module Sharing
  class Error < StandardError; end

  class NotFound < Error
    def initialize
      super("share link not found or expired")
    end
  end

  class NotShareable < Error
    def initialize(list)
      super("list #{list.slug} cannot be shared while #{list.state}")
    end
  end
end
