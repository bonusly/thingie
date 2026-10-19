class AdminPolicy < ApplicationPolicy
  def index?
    staff?
  end

  def show?
    staff?
  end

  def update?
    staff?
  end

  def suspend?
    staff? && record.active?
  end

  def unsuspend?
    staff? && !record.active?
  end

  def reindex?
    staff?
  end
end
