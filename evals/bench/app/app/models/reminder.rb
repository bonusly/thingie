class Reminder
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  CHANNELS = %w[email slack in_app].freeze

  field :remind_at, type: Time
  field :sent_at, type: Time
  field :channel, type: String, default: "in_app"

  belongs_to :task
  belongs_to :user

  index({ remind_at: 1, sent_at: 1 })
  index({ task_id: 1, user_id: 1 })

  validates :remind_at, presence: true
  validates :channel, inclusion: { in: CHANNELS }
  validate :remind_at_in_future, on: :create

  scope :pending, -> { where(sent_at: nil) }
  scope :due, ->(now = Time.current) { pending.where(:remind_at.lte => now) }

  def due?(now: Time.current)
    sent_at.nil? && remind_at <= now
  end

  def mark_sent!
    update!(sent_at: Time.current)
  end

  private

  def remind_at_in_future
    return if remind_at.nil? || remind_at > Time.current

    errors.add(:remind_at, :in_past)
  end
end
