module Admin
  class StatsController < BaseController
    ACTIVITY_WINDOW = 7.days

    def show
      render json: {
        companies: { total: Company.count, active: Company.active.count, suspended: Company.suspended.count },
        users: { total: User.count, staff: User.staff.count, seen_recently: User.seen_since(since).count },
        tasks: { open: Task.open.count, done: Task.done.count, archived: Task.where(state: "archived").count },
        drafts: { ready: DraftTask.ready.count, drafting: DraftTask.drafting.count },
        connectors: ConnectorAccount.connected.group_by(&:provider).transform_values(&:size),
        routes_indexed: RouteIndexEntry.count,
        window_days: (ACTIVITY_WINDOW / 1.day).to_i
      }
    end

    private

    def since
      ACTIVITY_WINDOW.ago
    end
  end
end
