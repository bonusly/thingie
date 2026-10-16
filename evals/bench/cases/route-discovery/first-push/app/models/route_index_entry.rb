class RouteIndexEntry
  include Mongoid::Document
  include Mongoid::Timestamps

  field :path, type: String
  field :name, type: String
  field :permission, type: String
  field :flag, type: String
  field :component, type: String
  field :unreadable, type: Boolean, default: false
  field :indexed_at, type: Time

  index({ path: 1 }, { unique: true })
  index({ permission: 1 })
  index({ flag: 1 })

  validates :path, presence: true, uniqueness: true, format: { with: %r{\A/} }
  validates :name, :component, presence: true

  scope :gated, -> { where(:permission.ne => nil) }
  scope :open_access, -> { where(permission: nil) }
  scope :flagged, -> { where(:flag.ne => nil) }
  scope :unreadable, -> { where(unreadable: true) }

  def gated?
    permission.present?
  end

  def flagged?
    flag.present?
  end

  def stale?(since:)
    indexed_at.nil? || indexed_at < since
  end
end
