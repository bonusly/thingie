module Tasks
  module Commands
    class Assign
      def self.call(task:, actor:, assignee_ids:)
        new(task: task, actor: actor, assignee_ids: assignee_ids).call
      end

      def initialize(task:, actor:, assignee_ids:)
        @task = task
        @actor = actor
        @assignee_ids = Array(assignee_ids).map { |id| BSON::ObjectId.from_string(id.to_s) }.uniq
      end

      def call
        return Result.failure(Tasks::InvalidTransition.new(task, :assign)) if task.archived?

        unknown = assignee_ids - member_ids
        return Result.failure("not members of this company: #{unknown.join(', ')}") if unknown.any?

        added = assignee_ids - task.assignee_ids
        removed = task.assignee_ids - assignee_ids
        task.update!(assignee_ids: assignee_ids)
        track(added, removed)
        notify(added)
        Result.success(task)
      end

      private

      attr_reader :task, :actor, :assignee_ids

      def member_ids
        @member_ids ||= task.company.memberships.active.pluck(:user_id)
      end

      def track(added, removed)
        TaskEvent.track!(task: task, actor: actor, kind: "assigned", data: { user_ids: added.map(&:to_s) }) if added.any?
        TaskEvent.track!(task: task, actor: actor, kind: "unassigned", data: { user_ids: removed.map(&:to_s) }) if removed.any?
      end

      def notify(added)
        User.in(id: added).each do |assignee|
          next if assignee.id == actor.id

          Notifications::Commands::Create.call(
            company: task.company, recipient: assignee, kind: "task_assigned", subject: task,
            payload: { title: task.title, assigned_by: actor.display_name }
          )
        end
      end
    end
  end
end
