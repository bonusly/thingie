module Tasks
  module Jobs
    class ArchiveStaleTasksJob
      include Sidekiq::Job

      sidekiq_options queue: :low, retry: 1

      STALE_AFTER = 30.days

      def perform(company_id = nil)
        companies = company_id ? Company.where(id: company_id) : Company.active

        companies.each do |company|
          stale_tasks(company).each do |task|
            Tasks::Commands::Archive.call(task: task, actor: nil)
          end
        end
      end

      private

      def stale_tasks(company)
        Task.for_company(company).done.where(:completed_at.lt => STALE_AFTER.ago)
      end
    end
  end
end
