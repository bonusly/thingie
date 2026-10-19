class WebhookDelivery
  include Mongoid::Document
  include Mongoid::Timestamps
  include AASM

  MAX_ATTEMPTS = 5

  field :event, type: String
  field :payload, type: Hash, default: {}
  field :response_status, type: Integer
  field :attempts, type: Integer, default: 0
  field :delivered_at, type: Time
  field :state, type: String, default: "pending"

  belongs_to :webhook

  index({ webhook_id: 1, created_at: -1 })
  index({ state: 1, updated_at: 1 })

  validates :event, presence: true

  aasm column: :state do
    state :pending, initial: true
    state :delivered
    state :failed

    event :deliver, after: ->(status) { update!(response_status: status, delivered_at: Time.current) } do
      transitions from: :pending, to: :delivered
    end

    event :reject, after: ->(status) { update!(response_status: status) } do
      transitions from: :pending, to: :failed
    end
  end

  scope :retryable, -> { where(state: "pending", :attempts.lt => MAX_ATTEMPTS) }

  def record_attempt!
    inc(attempts: 1)
  end

  def exhausted?
    attempts >= MAX_ATTEMPTS
  end
end
