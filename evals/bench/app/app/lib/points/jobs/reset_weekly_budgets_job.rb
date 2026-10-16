module Points
  module Jobs
    class ResetWeeklyBudgetsJob
      include Sidekiq::Job

      sidekiq_options queue: :low, retry: 2

      def perform(company_id = nil)
        scope = company_id ? Company.where(id: company_id) : Company.active

        scope.each do |company|
          result = Points::Commands::ResetWeeklyBudgets.call(company: company)
          logger.warn("reset failed for #{company.slug}: #{result.error}") if result.failure?
        end
      end
    end
  end
end
