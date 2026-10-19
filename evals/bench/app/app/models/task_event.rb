class TaskEvent
  include Mongoid::Document
  include Mongoid::Timestamps::Created
  include TenantScoped

  KINDS = %w[created updated completed reopened archived assigned unassigned commented points_awarded].freeze

  field :actor_id, type: BSON::ObjectId
  field :kind, type: String
  field :data, type: Hash, default: {}

  belongs_to :task, inverse_of: :events

  index({ task_id: 1, created_at: 1 })

  validates :kind, inclusion: { in: KINDS }

  scope :chronological, -> { order(created_at: :asc) }
  scope :of_kind, ->(kind) { where(kind: kind) }

  def self.track!(task:, actor:, kind:, data: {})
    create!(company: task.company, task: task, actor_id: actor&.id, kind: kind, data: data)
  end

  def actor
    User.where(id: actor_id).first if actor_id
  end
end
