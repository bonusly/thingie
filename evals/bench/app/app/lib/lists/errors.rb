module Lists
  class Error < StandardError; end

  class NotFound < Error
    def initialize(id)
      super("list #{id} not found")
    end
  end

  class Archived < Error
    def initialize(list)
      super("list #{list.slug} is archived")
    end
  end

  class NotAMember < Error
    def initialize(user, list)
      super("#{user.email} is not a member of list #{list.slug}")
    end
  end
end
