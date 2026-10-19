class User
  include Mongoid::Document
  include Mongoid::Timestamps
  include ActiveModel::SecurePassword

  EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  field :email, type: String
  field :name, type: String
  field :password_digest, type: String
  field :time_zone, type: String, default: "UTC"
  field :locale, type: String, default: "en"
  field :staff, type: Boolean, default: false
  field :last_seen_at, type: Time

  has_secure_password

  has_many :memberships, dependent: :destroy
  has_many :authored_tasks, class_name: "Task", inverse_of: :author
  has_many :draft_tasks, inverse_of: :author
  has_many :comments, inverse_of: :author
  has_many :notifications, inverse_of: :recipient, dependent: :destroy
    has_many :api_keys, dependent: :destroy
  has_many :connector_accounts, dependent: :destroy

  index({ email: 1 }, { unique: true })
  index({ staff: 1 })

  before_validation { self.email = email.to_s.strip.downcase }

  validates :email, presence: true, format: { with: EMAIL_FORMAT }, uniqueness: true
  validates :name, presence: true, length: { maximum: 80 }
  validates :locale, inclusion: { in: I18n.available_locales.map(&:to_s) }

  scope :staff, -> { where(staff: true) }
  scope :seen_since, ->(time) { where(:last_seen_at.gte => time) }

  def membership_for(company)
    memberships.active.where(company_id: company.id).first
  end

  def member_of?(company)
    membership_for(company).present?
  end

  def admin_of?(company)
    membership_for(company)&.admin? || false
  end

  def display_name
    name.presence || email.split("@").first
  end

  def touch_seen!
    set(last_seen_at: Time.current)
  end
end
