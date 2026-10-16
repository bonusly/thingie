class RouteIndexEntry
  include Mongoid::Document
  include Mongoid::Timestamps

  field :path, type: String
  field :name, type: String
  field :permission, type: String
  field :component, type: String
  field :indexed_at, type: Time

  index({ path: 1 }, { unique: true })
  index({ permission: 1 })

  validates :path, presence: true, uniqueness: true, format: { with: %r{\A/} }
  validates :name, :component, presence: true

  scope :gated, -> { where(:permission.ne => nil) }
  scope :open_access, -> { where(permission: nil) }

  def gated?
    permission.present?
  end

  def stale?(since:)
    indexed_at.nil? || indexed_at < since
  end
end
