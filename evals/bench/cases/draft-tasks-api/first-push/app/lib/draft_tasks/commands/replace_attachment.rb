module DraftTasks
  module Commands
    class ReplaceAttachment
      def self.call(draft:, actor:, attachment_id:)
        new(draft: draft, actor: actor, attachment_id: attachment_id).call
      end

      def initialize(draft:, actor:, attachment_id:)
        @draft = draft
        @actor = actor
        @attachment_id = attachment_id
      end

      def call
        return Result.failure(DraftTasks::NotEditable.new(draft)) unless draft.editable?
        return Result.failure("only the author can change the recording") unless draft.author_id == actor.id

        attachment = find_attachment
        return Result.failure(DraftTasks::InvalidAttachment.new(:not_found)) if attachment.nil?
        return Result.failure(DraftTasks::InvalidAttachment.new(:not_media)) unless attachment.media?
        return Result.failure(DraftTasks::InvalidAttachment.new(:claimed)) if attachment.claimed?

        draft.attachment&.destroy
        return Result.failure(attachment.errors.full_messages) unless attachment.update(draft_task_id: draft.id)

        draft.set(attachment_id: attachment.id)
        Result.success(draft)
      end

      private

      attr_reader :draft, :actor, :attachment_id

      def find_attachment
        Attachment.where(id: attachment_id).first
      end
    end
  end
end
