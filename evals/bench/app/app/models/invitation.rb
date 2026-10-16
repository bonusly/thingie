class Invitation
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped
  include Tokenized

  DEFAULT_TTL = 7.days

  field :email, type: String
  field :role, type: String, default: "member"
  field :accepted_at, type: Time
  field :expires_at, type: Time

  belongs_to :invited_by, class_name: "User", inverse_of: nil

  index({ company_id: 1, email: 1 })

  before_validation { self.email = email.to_s.strip.downcase }
  before_validation { self.expires_at ||= DEFAULT_TTL.from_now }

  validates :email, presence: true, format: { with: User::EMAIL_FORMAT }
  validates :role, inclusion: { in: Membership::ROLES }

  scope :pending, ->(now = Time.current) { where(accepted_at: nil, :expires_at.gt => now) }

  def accepted?
    accepted_at.present?
  end

  def expired?(now: Time.current)
    expires_at <= now
  end

  def accept!(user)
    membership = Membership.create!(company: company, user: user, role: role, joined_at: Time.current)
    update!(accepted_at: Time.current)
    membership
  end
end
