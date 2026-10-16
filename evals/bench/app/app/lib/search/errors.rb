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
end
