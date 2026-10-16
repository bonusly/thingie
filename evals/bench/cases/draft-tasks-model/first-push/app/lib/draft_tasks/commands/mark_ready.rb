module DraftTasks
  module Commands
    class MarkReady
      def self.call(draft:, actor:, now: Time.current)
        new(draft: draft, actor: actor, now: now).call
      end

      def initialize(draft:, actor:, now:)
        @draft = draft
        @actor = actor
        @now = now
      end

      def call
        DraftTasks::Services::WithLockedDraft.call(draft) do |locked|
          return Result.failure(DraftTasks::WrongState.new(locked, "drafting")) unless locked.may_mark_ready?
          return Result.failure("only the author can mark a draft ready") unless locked.author_id == actor.id

          reserve(locked)
        end
      rescue DraftTasks::Services::WithLockedDraft::Lock::Busy => e
        Result.failure(e.message)
      end

      private

      attr_reader :draft, :actor, :now

      def reserve(locked)
        balance = Points::Queries::GivingBalance.call(user: locked.author, company: locked.company, now: now)
        unless balance.covers?(locked.points)
          return Result.failure(Points::InsufficientBalance.new(requested: locked.points, remaining: balance.remaining))
        end

        locked.mark_ready!
        Result.success(locked)
      end
    end
  end
end
