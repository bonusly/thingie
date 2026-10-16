class ConnectorAccount
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped
  include AASM

  PROVIDERS = %w[github slack linear].freeze

  field :provider, type: String
  field :external_account_id, type: String
  field :external_account_name, type: String
  field :access_token_ciphertext, type: String
  field :cursor, type: String
  field :last_synced_at, type: Time
  field :last_error, type: String
  field :settings, type: Hash, default: {}
  field :state, type: String, default: "connected"

  belongs_to :user
  has_many :external_items, dependent: :destroy

  index({ company_id: 1, provider: 1, external_account_id: 1 }, { unique: true })
  index({ state: 1, last_synced_at: 1 })

  validates :provider, inclusion: { in: PROVIDERS }
  validates :external_account_id, presence: true

  aasm column: :state do
    state :connected, initial: true
    state :paused
    state :disconnected

    event :pause do
      transitions from: :connected, to: :paused
    end

    event :resume do
      transitions from: :paused, to: :connected
    end

    event :disconnect, after: -> { update!(access_token_ciphertext: nil, cursor: nil) } do
      transitions from: %i[connected paused], to: :disconnected
    end
  end

  scope :connected, -> { where(state: "connected") }
  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :stale, ->(before) { connected.where(:last_synced_at.lt => before) }

  def access_token
    return nil if access_token_ciphertext.blank?

    Lockbox.new(key: Lockbox.master_key).decrypt(Base64.strict_decode64(access_token_ciphertext))
  end

  def access_token=(raw)
    self.access_token_ciphertext = Base64.strict_encode64(Lockbox.new(key: Lockbox.master_key).encrypt(raw))
  end

  def touch_synced!(synced_at: Time.current)
    update!(last_synced_at: synced_at, cursor: nil, last_error: nil)
  end

  def record_error!(message)
    update!(last_error: message.to_s.truncate(500))
  end

  def setting(key)
    settings.fetch(key.to_s, nil)
  end
end
