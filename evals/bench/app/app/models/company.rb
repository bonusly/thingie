class Company
  include Mongoid::Document
  include Mongoid::Timestamps
  include Sluggable

  PLANS = %w[free team business].freeze

  field :name, type: String
  field :plan, type: String, default: "free"
  field :weekly_points_budget, type: Integer, default: 100
  field :week_starts_on, type: Integer, default: 1
  field :time_zone, type: String, default: "UTC"
  field :suspended_at, type: Time
  field :settings, type: Hash, default: {}

  has_many :memberships, dependent: :destroy
  has_many :lists, dependent: :destroy
  has_many :tasks, dependent: :destroy
  has_many :draft_tasks, dependent: :destroy
  has_many :labels, dependent: :destroy
  has_many :teams, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :webhooks, dependent: :destroy
  has_many :connector_accounts, dependent: :destroy
  has_many :invitations, dependent: :destroy

  index({ slug: 1 }, { unique: true })
  index({ suspended_at: 1 })

  validates :name, presence: true, length: { maximum: 120 }
  validates :plan, inclusion: { in: PLANS }
  validates :weekly_points_budget, numericality: { greater_than_or_equal_to: 0 }
  validates :week_starts_on, inclusion: { in: 0..6 }
  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) }

  scope :active, -> { where(suspended_at: nil) }
  scope :suspended, -> { where(:suspended_at.ne => nil) }

  def active?
    suspended_at.nil?
  end

  def suspend!
    update!(suspended_at: Time.current)
  end

  def unsuspend!
    update!(suspended_at: nil)
  end

  def users
    User.in(id: memberships.active.pluck(:user_id))
  end

  def admins
    User.in(id: memberships.active.admins.pluck(:user_id))
  end

  def setting(key)
    settings.fetch(key.to_s, nil)
  end
end
