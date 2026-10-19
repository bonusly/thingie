module Points
  module Services
    class WithLockedGiver
      TTL_SECONDS = 10

      class Busy < Points::Error
        def initialize(key)
          super("giver lock #{key} is held by another process")
        end
      end

      def self.call(user:, company:, &)
        new(user: user, company: company).call(&)
      end

      def initialize(user:, company:)
        @user = user
        @company = company
      end

      def call
        lock = RedisLock.new(key, ttl: TTL_SECONDS)
        raise Busy, key unless lock.acquire

        begin
          yield
        ensure
          lock.release
        end
      end

      private

      attr_reader :user, :company

      def key
        "locks:giver:#{company.id}:#{user.id}"
      end
    end
  end
end
