module Admin
  class BaseController < ApplicationController
    include AuthenticatesRequests
    include Paginates

    before_action :require_staff!

    private

    def require_staff!
      raise Admin::NotStaff, current_user unless current_user.staff?
    end

    def current_membership
      nil
    end

    def admin_authorize!(record, action)
      raise ApplicationPolicy::NotAuthorized, action unless AdminPolicy.new(current_user, record).public_send(action)
    end
  end
end
