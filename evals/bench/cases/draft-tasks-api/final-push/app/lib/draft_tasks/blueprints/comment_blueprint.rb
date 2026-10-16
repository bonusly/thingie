module DraftTasks
  module Blueprints
    class CommentBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :body, :edited_at, :created_at

      field :author_id, &:to_s
      field :from_draft, &:from_draft?
      field :draft do |comment|
        next nil unless comment.from_draft?

        draft = DraftTask.find(comment.draft_task_id)
        { id: draft.id.to_s, title: draft.title, author_id: draft.author_id.to_s }
      end
    end
  end
end
