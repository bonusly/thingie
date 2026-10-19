class AuditLog
  include Mongoid::Document
  include Mongoid::Timestamps::Created
  include TenantScoped

  field :actor_id, type: BSON::ObjectId
  field :action, type: String
  field :target_type, type: String
  field :target_id, type: BSON::ObjectId
  field :details, type: Hash, default: {}
  field :ip, type: String

  index({ company_id: 1, created_at: -1 })
  index({ target_type: 1, target_id: 1 })

  validates :action, presence: true

  scope :for_target, ->(target) { where(target_type: target.class.name, target_id: target.id) }
  scope :by_actor, ->(user) { where(actor_id: user.id) }

  def self.record!(company:, actor:, action:, target:, details: {}, ip: nil)
    create!(
      company: company,
      actor_id: actor&.id,
      action: action,
      target_type: target.class.name,
      target_id: target.id,
      details: details,
      ip: ip
    )
  end

  def actor
    User.where(id: actor_id).first if actor_id
  end
end
