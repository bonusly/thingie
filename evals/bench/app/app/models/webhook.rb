class Webhook
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  EVENTS = %w[task.created task.completed task.archived comment.created list.delivered draft_task.sent].freeze
  DISABLE_AFTER = 10

  field :url, type: String
  field :events, type: Array, default: []
  field :secret, type: String
  field :active, type: Boolean, default: true
  field :failure_count, type: Integer, default: 0

  has_many :deliveries, class_name: "WebhookDelivery", dependent: :destroy

  index({ company_id: 1, active: 1 })

  before_validation { self.secret ||= TokenGenerator.hex(20) }

  validates :url, presence: true, format: { with: %r{\Ahttps://}i }
  validates :events, presence: true
  validate :events_are_known

  scope :active, -> { where(active: true) }
  scope :subscribed_to, ->(event) { active.where(events: event) }

  def subscribed?(event)
    events.include?(event)
  end

  def record_failure!
    inc(failure_count: 1)
    update!(active: false) if failure_count >= DISABLE_AFTER
  end

  def record_success!
    set(failure_count: 0)
  end

  private

  def events_are_known
    unknown = events - EVENTS
    errors.add(:events, :unknown, events: unknown.join(", ")) if unknown.any?
  end
end
