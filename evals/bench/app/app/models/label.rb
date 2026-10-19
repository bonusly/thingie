class Label
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped
  include Sluggable

  COLOR_FORMAT = /\A#[0-9a-f]{6}\z/i

  field :name, type: String
  field :color, type: String, default: "#6b7280"

  index({ company_id: 1, slug: 1 }, { unique: true })

  validates :name, presence: true, length: { maximum: 40 }, uniqueness: { scope: :company_id, case_sensitive: false }
  validates :color, format: { with: COLOR_FORMAT }

  scope :alphabetical, -> { order(name: :asc) }

  def tasks
    Task.for_company(company).where(label_ids: id)
  end

  def task_count
    tasks.not_archived.count
  end
end
