class MembershipPolicy < ApplicationPolicy
  def update?
    same_company? && admin? && !self?
  end

  def destroy?
    same_company? && (admin? || self?) && !last_admin?
  end

  private

  def self?
    record.user_id == user.id
  end

  def last_admin?
    record.admin? && record.company.memberships.active.admins.count == 1
  end
end
