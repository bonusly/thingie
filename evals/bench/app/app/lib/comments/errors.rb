module Comments
  class Error < StandardError; end

  class NotFound < Error
    def initialize(id)
      super("comment #{id} not found")
    end
  end

  class NotAuthor < Error
    def initialize
      super("only the author can change this comment")
    end
  end
end
