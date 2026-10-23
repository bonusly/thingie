class List
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped
  include Sluggable
  include AASM

  VISIBILITIES = %w[private company public].freeze

  field :name, type: String
  field :description, type: String
  field :position, type: Integer, default: 0
  field :visibility, type: String, default: "company"
  field :state, type: String, default: "active"
  field :delivered_at, type: Time
  field :deleted_at, type: Time
  field :member_ids, type: Array, default: []

  belongs_to :owner, class_name: "User", inverse_of: nil
  has_many :tasks, dependent: :destroy
  has_many :draft_tasks, dependent: :nullify
  has_many :share_links, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy

  index({ company_id: 1, slug: 1 }, { unique: true })
  index({ company_id: 1, state: 1, position: 1 })
  index({ member_ids: 1 })

  validates :name, presence: true, length: { maximum: 120 }
  validates :visibility, inclusion: { in: VISIBILITIES }

  aasm column: :state do
    state :active, initial: true
    state :archived

    event :archive do
      transitions from: :active, to: :archived
    end

    event :restore do
      transitions from: :archived, to: :active
    end
  end

  scope :ordered, -> { order(position: :asc, name: :asc) }
  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :visible_to, ->(user) { any_of({ visibility: "company" }, { visibility: "public" }, { member_ids: user.id }, { owner_id: user.id }) }

  def members
    User.in(id: member_ids)
  end

  def member?(user)
    owner_id == user.id || member_ids.include?(user.id)
  end

  def public?
    visibility == "public"
  end

  def add_member(user)
    add_to_set(member_ids: user.id)
  end

  def remove_member(user)
    pull(member_ids: user.id)
  end

  def delivered?
    delivered_at.present?
  end

  def deleted?
    deleted_at.present?
  end
end
