module Notifications
  class Error < StandardError; end

  class NotFound < Error
    def initialize(id)
      super("notification #{id} not found")
    end
  end

  class NotRecipient < Error
    def initialize
      super("notification belongs to a different user")
    end
  end
end
