module Authorizes
  extend ActiveSupport::Concern

  def authorize!(record, action, policy: nil)
    policy_instance = (policy || policy_class_for(record)).new(current_user, record, membership: current_membership)
    return true if policy_instance.public_send(action)

    raise ApplicationPolicy::NotAuthorized, "#{action.to_s.delete_suffix('?')} #{record.class.name.underscore}"
  end

  private

  def policy_class_for(record)
    "#{record.class.name}Policy".constantize
  end
end
