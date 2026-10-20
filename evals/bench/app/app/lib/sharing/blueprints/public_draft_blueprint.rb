module Sharing
  module Blueprints
    class PublicDraftBlueprint < Blueprinter::Base
      identifier :id

      fields :title, :author_name, :scheduled_for, :attached_at, :points, :state

      field :author do |view|
        view.author_name && { name: view.author_name }
      end
      field :has_note do |view|
        view.draft.note.present?
      end
    end
  end
end
