class ApiKey
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  PREFIX_LENGTH = 8

  field :token_digest, type: String
  field :prefix, type: String
  field :label, type: String
  field :last_used_at, type: Time
  field :revoked_at, type: Time

  belongs_to :user

  index({ token_digest: 1 }, { unique: true })
  index({ company_id: 1, user_id: 1, revoked_at: 1 })

  validates :token_digest, :prefix, presence: true
  validates :label, length: { maximum: 60 }

  scope :active, -> { where(revoked_at: nil) }

  def self.generate(company:, user:, label: nil)
    raw = TokenGenerator.urlsafe(32)
    key = create!(company: company, user: user, label: label, prefix: raw[0, PREFIX_LENGTH], token_digest: digest(raw))
    [key, raw]
  end

  def self.authenticate(raw)
    return nil if raw.blank?

    active.where(token_digest: digest(raw)).first
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw)
  end

  def active?
    revoked_at.nil?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def touch_used!
    set(last_used_at: Time.current)
  end
end
