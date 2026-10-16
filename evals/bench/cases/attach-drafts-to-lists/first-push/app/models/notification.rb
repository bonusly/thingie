class Notification
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  KINDS = %w[
    task_assigned task_completed task_due_soon comment_added mentioned
    list_delivered draft_sent draft_conversion_failed points_awarded invitation
  ].freeze

  field :kind, type: String
  field :subject_type, type: String
  field :subject_id, type: BSON::ObjectId
  field :payload, type: Hash, default: {}
  field :read_at, type: Time

  belongs_to :recipient, class_name: "User", inverse_of: :notifications

  index({ recipient_id: 1, read_at: 1, created_at: -1 })
  index({ subject_type: 1, subject_id: 1 })

  validates :kind, inclusion: { in: KINDS }
  validates :subject_type, :subject_id, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_recipient, ->(user) { where(recipient_id: user.id) }

  def read?
    read_at.present?
  end

  def mark_read!
    return if read?

    update!(read_at: Time.current)
  end

  def subject
    subject_type.constantize.where(id: subject_id).first
  end
end
