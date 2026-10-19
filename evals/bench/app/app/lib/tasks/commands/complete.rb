module Tasks
  module Commands
    class Complete
      def self.call(task:, actor:)
        new(task: task, actor: actor).call
      end

      def initialize(task:, actor:)
        @task = task
        @actor = actor
      end

      def call
        return Result.failure(Tasks::InvalidTransition.new(task, :complete)) unless task.may_complete?

        task.complete!
        TaskEvent.track!(task: task, actor: actor, kind: "completed")
        notify_author
        WebhookDispatcher.dispatch(company: task.company, event: "task.completed", payload: { task_id: task.id.to_s })
        Result.success(task)
      end

      private

      attr_reader :task, :actor

      def notify_author
        return if task.author_id == actor.id

        Notifications::Commands::Create.call(
          company: task.company, recipient: task.author, kind: "task_completed", subject: task,
          payload: { title: task.title, completed_by: actor.display_name }
        )
      end
    end
  end
end
