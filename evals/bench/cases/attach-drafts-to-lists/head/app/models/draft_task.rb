class DraftTask
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped
  include AASM

  VISIBILITIES = %w[private shared].freeze

  field :title, type: String
  field :description, type: String
  field :note, type: String
  field :state, type: String, default: "drafting"
  field :points, type: Integer, default: 0
  field :due_on, type: Date
  field :scheduled_for, type: Time
  field :visibility, type: String, default: "shared"
  field :assignee_ids, type: Array, default: []
  field :label_ids, type: Array, default: []
  field :sent_task_id, type: BSON::ObjectId
  field :ready_at, type: Time
  field :sent_at, type: Time
  field :attached_at, type: Time

  belongs_to :list, optional: true
  belongs_to :author, class_name: "User", inverse_of: :draft_tasks

  index({ company_id: 1, author_id: 1, state: 1 })
  index({ list_id: 1, state: 1 })
  index({ state: 1, scheduled_for: 1 })

  validates :title, presence: true, length: { maximum: 200 }
  validates :points, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: Task::MAX_POINTS }
  validates :visibility, inclusion: { in: VISIBILITIES }

  aasm column: :state do
    state :drafting, initial: true
    state :ready
    state :sent

    event :mark_ready, after: -> { touch(:ready_at) } do
      transitions from: :drafting, to: :ready
    end

    event :mark_sent, after: ->(task) { update!(sent_at: Time.current, sent_task_id: task.id) } do
      transitions from: :ready, to: :sent
    end

    event :resume_drafting, after: -> { set(ready_at: nil) } do
      transitions from: :ready, to: :drafting
    end
  end

  scope :drafting, -> { where(state: "drafting") }
  scope :ready, -> { where(state: "ready") }
  scope :sent, -> { where(state: "sent") }
  scope :not_sent, -> { where(:state.ne => "sent") }
  scope :attached, -> { where(:list_id.ne => nil) }
  scope :unattached, -> { where(list_id: nil) }
  scope :by_author, ->(user) { where(author_id: user.id) }
  scope :scheduled_before, ->(time) { where(:scheduled_for.lte => time) }

  def private?
    visibility == "private"
  end

  def attached?
    list_id.present?
  end

  def reserved_points
    ready? ? points : 0
  end

  def sent_task
    Task.find(sent_task_id) if sent_task_id
  end

  def editable?
    drafting?
  end

  def task_attributes
    {
      title: title,
      description: description,
      due_on: due_on,
      points: points,
      assignee_ids: assignee_ids,
      label_ids: label_ids
    }
  end
end
