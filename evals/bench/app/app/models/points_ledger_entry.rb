class PointsLedgerEntry
  include Mongoid::Document
  include Mongoid::Timestamps::Created
  include TenantScoped

  KINDS = %w[award refund reset adjustment].freeze
  WEEK_KEY_FORMAT = /\A\d{4}-W\d{2}\z/

  field :amount, type: Integer
  field :kind, type: String
  field :week_key, type: String
  field :note, type: String

  belongs_to :user
  belongs_to :task, optional: true

  index({ company_id: 1, user_id: 1, week_key: 1, kind: 1 })
  index({ task_id: 1 }, { sparse: true })

  validates :amount, numericality: { only_integer: true, other_than: 0 }
  validates :kind, inclusion: { in: KINDS }
  validates :week_key, format: { with: WEEK_KEY_FORMAT }

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :for_week, ->(week_key) { where(week_key: week_key) }
  scope :awards, -> { where(kind: "award") }
  scope :refunds, -> { where(kind: "refund") }
  scope :chronological, -> { order(created_at: :asc) }

  def award?
    kind == "award"
  end

  def signed_amount
    award? ? -amount : amount
  end
end
