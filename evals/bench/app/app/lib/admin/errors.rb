module Admin
  class Error < StandardError; end

  class NotStaff < Error
    def initialize(user)
      super("#{user&.email || 'anonymous'} is not staff")
    end
  end

  class AlreadySuspended < Error
    def initialize(company)
      super("#{company.slug} is already suspended")
    end
  end
end
