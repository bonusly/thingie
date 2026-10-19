module Points
  module Queries
    class WeeklyWindow
      Window = Struct.new(:starts_at, :ends_at, :key, keyword_init: true) do
        def cover?(time)
          time >= starts_at && time < ends_at
        end
      end

      def self.call(company:, now: Time.current)
        new(company: company, now: now).call
      end

      def initialize(company:, now:)
        @company = company
        @now = now
      end

      def call
        local = now.in_time_zone(company.time_zone)
        days_back = (local.wday - company.week_starts_on) % 7
        starts_at = (local - days_back.days).beginning_of_day
        Window.new(starts_at: starts_at, ends_at: starts_at + 7.days, key: key_for(starts_at))
      end

      private

      attr_reader :company, :now

      def key_for(starts_at)
        format("%04d-W%02d", starts_at.to_date.cwyear, starts_at.to_date.cweek)
      end
    end
  end
end
