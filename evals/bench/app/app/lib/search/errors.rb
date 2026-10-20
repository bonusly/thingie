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

  class ParseError < Error
    def initialize(path, position)
      super("unbalanced brackets in #{path} near offset #{position}")
    end
  end

  class UnresolvedConstant < Error
    def initialize(reference)
      super("could not resolve #{reference} from the router's imports")
    end
  end
end
