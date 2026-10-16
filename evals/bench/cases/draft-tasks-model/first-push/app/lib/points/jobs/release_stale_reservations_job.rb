module Points
  module Jobs
    class ReleaseStaleReservationsJob
      include Sidekiq::Job

      sidekiq_options queue: :low, retry: 2

      def perform(company_id = nil)
        scope = company_id ? Company.where(id: company_id) : Company.active

        scope.each do |company|
          result = Points::Commands::ReleaseStaleReservations.call(company: company)
          logger.info("released #{result.value[:released]} stale reservations for #{company.slug}")
        end
      end
    end
  end
end
