module Tasks
  module Commands
    class Reopen
      def self.call(task:, actor:)
        new(task: task, actor: actor).call
      end

      def initialize(task:, actor:)
        @task = task
        @actor = actor
      end

      def call
        return Result.failure(Tasks::InvalidTransition.new(task, :reopen)) unless task.may_reopen?

        task.reopen!
        TaskEvent.track!(task: task, actor: actor, kind: "reopened")
        Result.success(task)
      end

      private

      attr_reader :task, :actor
    end
  end
end
