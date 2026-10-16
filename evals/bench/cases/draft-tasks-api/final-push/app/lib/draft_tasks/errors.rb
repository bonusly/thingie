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

  class ReadOnlyKeys < Error
    attr_reader :keys

    def initialize(keys)
      @keys = keys
      super(I18n.t("draft_tasks.errors.read_only", keys: keys.join(", ")))
    end
  end

  class InvalidAttachment < Error
    def initialize(reason)
      super(I18n.t("draft_tasks.errors.attachment.#{reason}", max: Attachment::MEDIA_MAX_BYTES / 1.megabyte))
    end
  end
end
