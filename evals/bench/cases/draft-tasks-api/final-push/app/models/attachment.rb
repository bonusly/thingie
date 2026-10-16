class Attachment
  include Mongoid::Document
  include Mongoid::Timestamps
  include TenantScoped

  MAX_BYTES = 25.megabytes
  MEDIA_MAX_BYTES = 10.megabytes
  IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
  AUDIO_TYPES = %w[audio/mpeg audio/mp4 audio/webm audio/ogg].freeze
  VIDEO_TYPES = %w[video/mp4 video/webm video/quicktime].freeze

  field :filename, type: String
  field :content_type, type: String
  field :byte_size, type: Integer
  field :storage_key, type: String
  field :checksum, type: String
  field :draft_task_id, type: BSON::ObjectId

  belongs_to :task, optional: true
  belongs_to :uploader, class_name: "User", inverse_of: nil

  index({ task_id: 1, created_at: 1 })
  index({ draft_task_id: 1 }, { sparse: true })
  index({ storage_key: 1 }, { unique: true })

  validates :filename, :content_type, :storage_key, presence: true
  validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_BYTES }
  validates :byte_size, numericality: { less_than_or_equal_to: MEDIA_MAX_BYTES }, if: :media?

  def image?
    IMAGE_TYPES.include?(content_type)
  end

  def audio?
    AUDIO_TYPES.include?(content_type)
  end

  def video?
    VIDEO_TYPES.include?(content_type)
  end

  def media?
    audio? || video?
  end

  def media_kind
    return "audio" if audio?
    return "video" if video?

    nil
  end

  def claimed?
    task_id.present? || draft_task_id.present?
  end

  def extension
    File.extname(filename).delete(".").downcase
  end

  def human_size
    ActiveSupport::NumberHelper.number_to_human_size(byte_size)
  end
end
