module DraftTasks
  module Commands
    class Update
      PERMITTED = DraftTasks::Commands::Create::PERMITTED

      def self.call(**)
        new(**).call
      end

      def initialize(draft:, actor:, attrs:)
        @draft = draft
        @actor = actor
        @attrs = attrs.to_h.symbolize_keys.slice(*PERMITTED)
      end

      def call
        return Result.failure(DraftTasks::NotEditable.new(draft)) unless draft.editable?
        return Result.failure("only the author can edit a draft") unless draft.author_id == actor.id

        draft.assign_attributes(attrs)
        return Result.failure(draft.errors.full_messages) unless draft.valid?
        return Result.success(draft) if changes.empty?

        DraftTask.where(_id: draft.id).find_one_and_update({ "$set" => changes.merge(updated_at: Time.current) })
        Result.success(draft.reload)
      end

      private

      attr_reader :draft, :actor, :attrs

      def changes
        @changes ||= draft.changes.transform_values(&:last)
      end
    end
  end
end
