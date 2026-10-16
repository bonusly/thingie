module Admin
  module Queries
    class CompanyStats
      Stats = Struct.new(:company, :members, :admins, :lists, :open_tasks, :done_tasks, :ready_drafts,
                         :points_awarded_this_week, :connected_accounts, keyword_init: true)

      def self.call(company:, now: Time.current)
        new(company: company, now: now).call
      end

      def initialize(company:, now:)
        @company = company
        @now = now
      end

      def call
        Stats.new(
          company: company,
          members: company.memberships.active.count,
          admins: company.memberships.active.admins.count,
          lists: company.lists.where(state: "active").count,
          open_tasks: company.tasks.open.count,
          done_tasks: company.tasks.done.count,
          ready_drafts: company.draft_tasks.ready.count,
          points_awarded_this_week: points_this_week,
          connected_accounts: company.connector_accounts.connected.count
        )
      end

      private

      attr_reader :company, :now

      def points_this_week
        week = Points::Queries::WeeklyWindow.call(company: company, now: now)
        PointsLedgerEntry.for_company(company).for_week(week.key).awards.sum(:amount)
      end
    end
  end
end
