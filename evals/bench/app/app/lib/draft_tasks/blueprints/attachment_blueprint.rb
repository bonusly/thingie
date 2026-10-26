module DraftTasks
  module Blueprints
    class AttachmentBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :filename, :content_type, :byte_size, :created_at

      field :uploader_id, &:to_s
      field :media_kind, &:media_kind
      field :human_size, &:human_size
    end
  end
end
