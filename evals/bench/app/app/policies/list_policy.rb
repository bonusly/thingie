class ListPolicy < ApplicationPolicy
  def show?
    same_company? && (record.public? || record.visibility == "company" || record.member?(user))
  end

  def update?
    same_company? && (owner? || admin?)
  end

  def deliver?
    same_company? && record.member?(user) && record.active?
  end

  def archive?
    update?
  end

  def restore?
    update?
  end

  def share?
    same_company? && record.member?(user)
  end

  def comment?
    show?
  end

  def destroy?
    same_company? && (owner? || admin?) && record.archived?
  end

  private

  def owner?
    record.owner_id == user.id
  end
end
