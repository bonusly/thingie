class Comment
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  MAX_BODY = 5_000

  field :body, type: String
  field :mentioned_user_ids, type: Array, default: []
  field :edited_at, type: Time
  field :draft_task_id, type: BSON::ObjectId

  belongs_to :commentable, polymorphic: true
  belongs_to :author, class_name: "User", inverse_of: :comments

  index({ commentable_type: 1, commentable_id: 1, created_at: 1 })
  index({ company_id: 1, author_id: 1 })

  validates :body, presence: true, length: { maximum: MAX_BODY }

  scope :chronological, -> { order(created_at: :asc) }
  scope :by_author, ->(user) { where(author_id: user.id) }

  def edited?
    edited_at.present?
  end

  def mentions
    User.in(id: mentioned_user_ids)
  end

  def from_draft?
    draft_task_id.present?
  end

  def editable_by?(user)
    author_id == user.id
  end
end
