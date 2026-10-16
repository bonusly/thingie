module Tasks
  module Commands
    class Update
      PERMITTED = %i[title description due_on position label_ids].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(task:, actor:, attrs:)
        @task = task
        @actor = actor
        @attrs = attrs.to_h.symbolize_keys.slice(*PERMITTED)
      end

      def call
        return Result.failure(Tasks::InvalidTransition.new(task, :update)) if task.archived?

        task.assign_attributes(attrs)
        changed = task.changes.keys
        return Result.success(task) if changed.empty?
        return Result.failure(task.errors.full_messages) unless task.save

        TaskEvent.track!(task: task, actor: actor, kind: "updated", data: { fields: changed })
        Result.success(task)
      end

      private

      attr_reader :task, :actor, :attrs
    end
  end
end
