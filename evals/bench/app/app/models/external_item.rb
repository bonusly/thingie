class ExternalItem
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  KINDS = %w[issue pull_request message channel project].freeze

  field :provider, type: String
  field :external_id, type: String
  field :kind, type: String
  field :title, type: String
  field :url, type: String
  field :payload, type: Hash, default: {}
  field :external_updated_at, type: Time
  field :imported_task_id, type: BSON::ObjectId

  belongs_to :connector_account

  index({ company_id: 1, provider: 1, external_id: 1 }, { unique: true })
  index({ connector_account_id: 1, external_updated_at: -1 })

  validates :provider, inclusion: { in: ConnectorAccount::PROVIDERS }
  validates :kind, inclusion: { in: KINDS }
  validates :external_id, :title, presence: true

  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :unimported, -> { where(imported_task_id: nil) }
  scope :newest_first, -> { order(external_updated_at: :desc) }

  def imported?
    imported_task_id.present?
  end

  def imported_task
    Task.where(id: imported_task_id).first if imported?
  end

  def mark_imported!(task)
    update!(imported_task_id: task.id)
  end
end
