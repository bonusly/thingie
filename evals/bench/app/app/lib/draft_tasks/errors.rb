module DraftTasks
  class Error < StandardError; end

  class NotFound < Error
    def initialize(id)
      super("draft task #{id} not found")
    end
  end

  class NotEditable < Error
    def initialize(draft)
      super("draft #{draft.id} is #{draft.state} and cannot be edited")
    end
  end

  class WrongState < Error
    def initialize(draft, expected)
      super("draft #{draft.id} is #{draft.state}, expected #{expected}")
    end
  end
end
