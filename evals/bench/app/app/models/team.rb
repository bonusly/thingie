class Team
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped
  include Sluggable

  field :name, type: String
  field :lead_id, type: BSON::ObjectId
  field :member_ids, type: Array, default: []

  index({ company_id: 1, slug: 1 }, { unique: true })
  index({ member_ids: 1 })

  validates :name, presence: true, length: { maximum: 80 }, uniqueness: { scope: :company_id }

  scope :with_member, ->(user) { where(member_ids: user.id) }

  def lead
    User.where(id: lead_id).first if lead_id
  end

  def members
    User.in(id: member_ids)
  end

  def member?(user)
    member_ids.include?(user.id)
  end

  def add_member(user)
    add_to_set(member_ids: user.id)
  end

  def size
    member_ids.size
  end
end
