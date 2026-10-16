module Points
  class Error < StandardError; end

  class InsufficientBalance < Error
    attr_reader :requested, :remaining

    def initialize(requested:, remaining:)
      @requested = requested
      @remaining = remaining
      super("requested #{requested} points but only #{remaining} remain this week")
    end
  end

  class NotAMember < Error
    def initialize(user, company)
      super("#{user.email} is not a member of #{company.slug}")
    end
  end
end
