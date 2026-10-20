module DraftTasks
  module Commands
    class MarkReady
      FINAL_EDITS = %i[note scheduled_for].freeze

      def self.call(draft:, actor:, edits: {}, now: Time.current)
        new(draft: draft, actor: actor, edits: edits, now: now).call
      end

      def initialize(draft:, actor:, edits:, now:)
        @draft = draft
        @actor = actor
        @edits = edits.to_h.symbolize_keys.slice(*FINAL_EDITS)
        @now = now
      end

      def call
        DraftTasks::Services::WithLockedDraft.call(draft) do |locked|
          return Result.failure(DraftTasks::WrongState.new(locked, "drafting")) unless locked.may_mark_ready?
          return Result.failure("only the author can mark a draft ready") unless locked.author_id == actor.id

          balance = Points::Queries::GivingBalance.call(user: locked.author, company: locked.company, now: now)
          unless balance.covers?(locked.points)
            return Result.failure(Points::InsufficientBalance.new(requested: locked.points, remaining: balance.remaining))
          end

          locked.assign_attributes(edits)
          return Result.failure(locked.errors.full_messages) unless locked.valid?

          locked.mark_ready!
          Result.success(locked)
        end
      rescue DraftTasks::Commands::SendDraft::Lock::Busy => e
        Result.failure(e)
      end

      private

      attr_reader :draft, :actor, :edits, :now
    end
  end
end
