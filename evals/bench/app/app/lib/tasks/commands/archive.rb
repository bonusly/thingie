module Tasks
  module Commands
    class Archive
      def self.call(task:, actor:)
        new(task: task, actor: actor).call
      end

      def initialize(task:, actor:)
        @task = task
        @actor = actor
      end

      def call
        return Result.failure(Tasks::InvalidTransition.new(task, :archive)) unless task.may_archive?

        task.archive!
        task.reminders.pending.delete_all
        TaskEvent.track!(task: task, actor: actor, kind: "archived")
        WebhookDispatcher.dispatch(company: task.company, event: "task.archived", payload: { task_id: task.id.to_s })
        Result.success(task)
      end

      private

      attr_reader :task, :actor
    end
  end
end
