class Membership
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  ROLES = %w[member admin].freeze
  STATES = %w[active removed].freeze

  field :role, type: String, default: "member"
  field :state, type: String, default: "active"
  field :points_budget_override, type: Integer
  field :joined_at, type: Time
  field :removed_at, type: Time

  belongs_to :user

  index({ company_id: 1, user_id: 1 }, { unique: true })
  index({ user_id: 1, state: 1 })

  validates :role, inclusion: { in: ROLES }
  validates :state, inclusion: { in: STATES }
  validates :user_id, uniqueness: { scope: :company_id }
  validates :points_budget_override, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(state: "active") }
  scope :admins, -> { where(role: "admin") }
  scope :members, -> { where(role: "member") }
  scope :for_user, ->(user) { where(user_id: user.id) }

  def admin?
    role == "admin"
  end

  def active?
    state == "active"
  end

  def points_budget
    points_budget_override || company.weekly_points_budget
  end

  def remove!
    update!(state: "removed", removed_at: Time.current)
  end

  def promote!
    update!(role: "admin")
  end

  def demote!
    update!(role: "member")
  end
end
