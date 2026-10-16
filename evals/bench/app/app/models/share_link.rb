class ShareLink
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped
  include Tokenized

  token_length 32

  field :expires_at, type: Time
  field :revoked_at, type: Time
  field :show_drafts, type: Boolean, default: false
  field :view_count, type: Integer, default: 0

  belongs_to :list
  belongs_to :created_by, class_name: "User", inverse_of: nil

  index({ list_id: 1, revoked_at: 1 })

  validates :expires_at, presence: true

  scope :active, ->(now = Time.current) { where(revoked_at: nil, :expires_at.gt => now) }

  def self.find_active(token, now: Time.current)
    active(now).where(token: token).first
  end

  def active?(now: Time.current)
    revoked_at.nil? && expires_at > now
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def record_view!
    inc(view_count: 1)
  end
end
