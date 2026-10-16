class ShareLinkPolicy < ApplicationPolicy
  def index?
    same_company? && record.list.member?(user)
  end

  def show?
    index?
  end

  def create?
    ListPolicy.new(user, record.list, membership: membership).share?
  end

  def destroy?
    same_company? && (creator? || record.list.owner_id == user.id || admin?)
  end

  private

  def creator?
    record.created_by_id == user.id
  end
end
