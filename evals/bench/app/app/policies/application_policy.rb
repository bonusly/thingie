class ApplicationPolicy
  class NotAuthorized < StandardError
    def initialize(action)
      super("not allowed to #{action}")
    end
  end

  attr_reader :user, :record, :membership

  def initialize(user, record, membership: nil)
    @user = user
    @record = record
    @membership = membership
  end

  def index?
    member?
  end

  def show?
    member?
  end

  def create?
    member?
  end

  def update?
    admin?
  end

  def destroy?
    admin?
  end

  private

  def member?
    membership.present? && membership.active?
  end

  def admin?
    member? && membership.admin?
  end

  def staff?
    user&.staff? || false
  end

  def same_company?
    record.respond_to?(:company_id) && membership && record.company_id == membership.company_id
  end
end
