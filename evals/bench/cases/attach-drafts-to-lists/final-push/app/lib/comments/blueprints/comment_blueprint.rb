module Comments
  module Blueprints
    class CommentBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :body, :edited_at, :created_at, :updated_at

      field :author_id, &:to_s
      field :commentable_type
      field :commentable_id, &:to_s
      field :mentioned_user_ids do |comment|
        comment.mentioned_user_ids.map(&:to_s)
      end
      field :from_draft, &:from_draft?
      field :draft do |comment|
        draft = comment.draft
        draft && { id: draft.id.to_s, title: draft.title, state: draft.state, points: draft.points }
      end
    end
  end
end
