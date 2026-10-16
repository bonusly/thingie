module Sharing
  module Blueprints
    class PublicDraftBlueprint < Blueprinter::Base
      identifier :id

      fields :title, :author_name, :scheduled_for, :attached_at, :points, :state

      field :author do |view|
        { id: view.draft.author_id.to_s, name: view.draft.author.name }
      end
      field :has_note do |view|
        view.draft.note.present?
      end
    end
  end
end
