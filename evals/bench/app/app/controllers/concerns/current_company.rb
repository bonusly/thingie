module CurrentCompany
  extend ActiveSupport::Concern

  class NotAMember < StandardError; end

  def current_company
    @current_company ||= current_api_key.company
  end

  def current_membership
    @current_membership ||= current_user.membership_for(current_company) || raise(NotAMember)
  end

  def require_admin!
    raise ApplicationPolicy::NotAuthorized, action_name unless current_membership.admin?
  end
end
