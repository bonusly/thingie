class ConnectorAccountPolicy < ApplicationPolicy
  def show?
    same_company? && (owner? || admin?)
  end

  def sync?
    show? && record.connected?
  end

  def pause?
    show? && record.may_pause?
  end

  def resume?
    show? && record.may_resume?
  end

  def destroy?
    show? && record.may_disconnect?
  end

  private

  def owner?
    record.user_id == user.id
  end
end
