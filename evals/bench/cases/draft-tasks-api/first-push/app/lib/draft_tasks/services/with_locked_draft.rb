module DraftTasks
  module Services
    class WithLockedDraft
      TTL_SECONDS = 15

      def self.call(draft, &)
        new(draft).call(&)
      end

      def initialize(draft)
        @draft = draft
      end

      def call
        lock = RedisLock.new(key, ttl: TTL_SECONDS)
        raise DraftTasks::Commands::SendDraft::Lock::Busy, key unless lock.acquire

        begin
          yield draft.reload
        ensure
          lock.release
        end
      end

      private

      attr_reader :draft

      def key
        "locks:draft_task:#{draft.id}"
      end
    end
  end
end
