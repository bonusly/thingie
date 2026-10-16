module Admin
  class CompaniesController < BaseController
    BLUEPRINT = Admin::Blueprints::CompanyBlueprint

    def index
      companies = Admin::Queries::ListCompanies.call(filters: filters, page: page, per_page: per_page)
      render json: BLUEPRINT.render(companies)
    end

    def show
      render json: BLUEPRINT.render(company, view: :with_stats)
    end

    def update
      company.update!(params.require(:company).permit(:name, :plan, :weekly_points_budget, :week_starts_on, :time_zone))
      render json: BLUEPRINT.render(company)
    end

    def suspend
      admin_authorize!(company, :suspend?)
      result = Admin::Commands::SuspendCompany.call(company: company, actor: current_user, reason: params[:reason])
      render_admin_result(result)
    end

    def unsuspend
      admin_authorize!(company, :unsuspend?)
      render_admin_result(Admin::Commands::UnsuspendCompany.call(company: company, actor: current_user))
    end

    private

    def company
      @company ||= Company.find(params[:id])
    end

    def filters
      permitted = params.permit(:plan, :q, :suspended).to_h.symbolize_keys
      permitted[:suspended] = ActiveModel::Type::Boolean.new.cast(permitted[:suspended]) if permitted.key?(:suspended)
      permitted
    end

    def render_admin_result(result)
      raise result.error if result.failure? && result.error.is_a?(Exception)
      return render json: { error: result.error }, status: :unprocessable_entity if result.failure?

      render json: BLUEPRINT.render(result.value, view: :with_stats)
    end
  end
end
