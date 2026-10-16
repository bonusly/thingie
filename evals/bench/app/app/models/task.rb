class Task
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped
  include AASM

  MAX_POINTS = 50

  field :title, type: String
  field :description, type: String
  field :state, type: String, default: "open"
  field :due_on, type: Date
  field :completed_at, type: Time
  field :archived_at, type: Time
  field :points, type: Integer, default: 0
  field :position, type: Integer, default: 0
  field :assignee_ids, type: Array, default: []
  field :label_ids, type: Array, default: []

  belongs_to :list
  belongs_to :author, class_name: "User", inverse_of: :authored_tasks
  belongs_to :external_item, optional: true
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :attachments, dependent: :destroy
  has_many :reminders, dependent: :destroy
  has_many :events, class_name: "TaskEvent", dependent: :destroy

  index({ company_id: 1, list_id: 1, state: 1, position: 1 })
  index({ company_id: 1, assignee_ids: 1, state: 1 })
  index({ company_id: 1, due_on: 1 })
  index({ external_item_id: 1 }, { sparse: true })

  validates :title, presence: true, length: { maximum: 200 }
  validates :points, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_POINTS }
  validate :list_belongs_to_company

  aasm column: :state do
    state :open, initial: true
    state :done
    state :archived

    event :complete, after: -> { touch(:completed_at) } do
      transitions from: :open, to: :done
    end

    event :reopen, after: -> { set(completed_at: nil) } do
      transitions from: :done, to: :open
    end

    event :archive, after: -> { touch(:archived_at) } do
      transitions from: %i[open done], to: :archived
    end
  end

  scope :open, -> { where(state: "open") }
  scope :done, -> { where(state: "done") }
  scope :not_archived, -> { where(:state.ne => "archived") }
  scope :overdue, ->(today = Date.current) { open.where(:due_on.lt => today) }
  scope :assigned_to, ->(user) { where(assignee_ids: user.id) }
  scope :with_points, -> { where(:points.gt => 0) }
  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  def overdue?(today: Date.current)
    open? && due_on.present? && due_on < today
  end

  def assigned_to?(user)
    assignee_ids.include?(user.id)
  end

  def assignees
    User.in(id: assignee_ids)
  end

  def labels
    Label.in(id: label_ids)
  end

  def rewarded?
    points.positive?
  end

  private

  def list_belongs_to_company
    return if list.nil? || list.company_id == company_id

    errors.add(:list, :wrong_company)
  end
end
