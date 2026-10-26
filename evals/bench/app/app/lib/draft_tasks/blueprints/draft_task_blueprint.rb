module DraftTasks
  module Blueprints
    class DraftTaskBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :title, :description, :note, :state, :points, :due_on, :scheduled_for, :visibility,
             :ready_at, :points_reserved_at, :sent_at, :revision, :created_at, :updated_at

      field :list_id, &:to_s
      field :author_id, &:to_s
      field :last_edited_by_id do |draft|
        draft.last_edited_by_id&.to_s
      end
      field :sent_task_id do |draft|
        draft.sent_task_id&.to_s
      end
      field :assignee_ids do |draft|
        draft.assignee_ids.map(&:to_s)
      end
      field :label_ids do |draft|
        draft.label_ids.map(&:to_s)
      end
      field :attachment do |draft|
        recording = draft.attachment
        recording && DraftTasks::Blueprints::AttachmentBlueprint.render_as_hash(recording)
      end
      field :reserved_points, &:reserved_points
      field :editable, &:editable?
    end
  end
end
