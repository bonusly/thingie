module Tasks
  module Blueprints
    class AttachmentBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :filename, :content_type, :byte_size, :created_at

      field :task_id, &:to_s
      field :uploader_id, &:to_s
      field :image, &:image?
      field :extension, &:extension
      field :human_size, &:human_size
    end
  end
end
