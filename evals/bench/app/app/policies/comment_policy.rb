class CommentPolicy < ApplicationPolicy
  def show?
    same_company? && commentable_visible?
  end

  def create?
    show?
  end

  def update?
    same_company? && record.editable_by?(user)
  end

  def destroy?
    same_company? && (record.editable_by?(user) || admin?)
  end

  private

  def commentable_visible?
    case record.commentable
    when Task then TaskPolicy.new(user, record.commentable, membership: membership).show?
    when List then ListPolicy.new(user, record.commentable, membership: membership).show?
    else false
    end
  end
end
