module Tasks
  class Error < StandardError; end

  class NotFound < Error
    def initialize(id)
      super("task #{id} not found")
    end
  end

  class WrongCompany < Error
    def initialize
      super("list does not belong to this company")
    end
  end

  class InvalidTransition < Error
    def initialize(task, event)
      super("cannot #{event} task #{task.id} in state #{task.state}")
    end
  end
end
