class TaskPolicy < ApplicationPolicy
  def show?
    same_company? && list_visible?
  end

  def create?
    member? && record.list.member?(user)
  end

  def update?
    show? && (author? || assignee? || admin?)
  end

  def complete?
    show? && (assignee? || author? || admin?)
  end

  def reopen?
    complete?
  end

  def archive?
    show? && (author? || admin?)
  end

  def assign?
    show? && record.list.member?(user)
  end

  def destroy?
    archive?
  end

  private

  def author?
    record.author_id == user.id
  end

  def assignee?
    record.assigned_to?(user)
  end

  def list_visible?
    list = record.list
    list.public? || list.visibility == "company" || list.member?(user)
  end
end
