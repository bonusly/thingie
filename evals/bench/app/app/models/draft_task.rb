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
  field :attachment_id, type: BSON::ObjectId
  field :ready_at, type: Time
  field :points_reserved_at, type: Time
  field :sent_at, type: Time
  field :revision, type: Integer, default: 1
  field :last_edited_by_id, type: BSON::ObjectId

  belongs_to :list
  belongs_to :author, class_name: "User", inverse_of: :draft_tasks

  index({ company_id: 1, author_id: 1, state: 1 })
  index({ list_id: 1, state: 1 })
  index({ state: 1, scheduled_for: 1 })
  index({ attachment_id: 1 }, { sparse: true })

  validates :title, presence: true, length: { maximum: 200 }
  validates :points, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: Task::MAX_POINTS }
  validates :visibility, inclusion: { in: VISIBILITIES }

  aasm column: :state do
    state :drafting, initial: true
    state :ready
    state :sent

    event :mark_ready, after: :reserve_points! do
      transitions from: :drafting, to: :ready
    end
  end

  scope :drafting, -> { where(state: "drafting") }
  scope :ready, -> { where(state: "ready") }
  scope :sent, -> { where(state: "sent") }
  scope :by_author, ->(user) { where(author_id: user.id) }
  scope :scheduled_before, ->(time) { where(:scheduled_for.lte => time) }

  def mark_sent!(task)
    claim!(from: "ready", to: "sent", sent_at: Time.current, sent_task_id: task.id)
  end

  def resume_drafting!
    claim!(from: "ready", to: "drafting", ready_at: nil, points_reserved_at: nil)
  end

  def claim!(from:, to:, **changes)
    claimed = DraftTask.where(id: id, state: from).find_one_and_update(
      { "$set" => changes.merge(state: to) }, return_document: :after
    )
    raise DraftTasks::WrongState.new(self, from) if claimed.nil?

    reload
  end

  def private?
    visibility == "private"
  end

  def reserved_points
    ready? ? points : 0
  end

  def sent_task
    Task.find(sent_task_id) if sent_task_id
  end

  def attachment
    Attachment.where(id: attachment_id).first if attachment_id
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
      label_ids: label_ids,
      draft_task_id: id
    }
  end

  private

  def reserve_points!
    now = Time.current
    set(ready_at: now, points_reserved_at: now)
  end
end
