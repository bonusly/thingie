module RequiresFeature
  extend ActiveSupport::Concern

  private

  def require_feature!(flag)
    raise Features::Disabled, flag unless Features.enabled?(flag, current_company)
  end
end
