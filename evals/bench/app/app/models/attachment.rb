class Attachment
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  MAX_BYTES = 25.megabytes
  IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze

  field :filename, type: String
  field :content_type, type: String
  field :byte_size, type: Integer
  field :storage_key, type: String
  field :checksum, type: String

  belongs_to :task
  belongs_to :uploader, class_name: "User", inverse_of: nil

  index({ task_id: 1, created_at: 1 })
  index({ storage_key: 1 }, { unique: true })

  validates :filename, :content_type, :storage_key, presence: true
  validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_BYTES }

  def image?
    IMAGE_TYPES.include?(content_type)
  end

  def extension
    File.extname(filename).delete(".").downcase
  end

  def human_size
    ActiveSupport::NumberHelper.number_to_human_size(byte_size)
  end
end
