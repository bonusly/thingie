class DraftTaskPolicy < ApplicationPolicy
  def show?
    same_company? && (author? || admin? || shared_with_me?)
  end

  def create?
    member? && record.list.member?(user)
  end

  def update?
    same_company? && author? && record.editable?
  end

  def mark_ready?
    same_company? && author? && record.drafting? && Features.enabled?(:draft_tasks, user)
  end

  def release?
    same_company? && (author? || admin?) && !record.sent?
  end

  def send_now?
    same_company? && (author? || admin?) && record.ready?
  end

  def destroy?
    same_company? && author? && !record.sent?
  end

  private

  def author?
    record.author_id == user.id
  end

  def shared_with_me?
    !record.private? && record.list.member?(user)
  end
end
