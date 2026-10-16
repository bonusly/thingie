module DraftTasks
  module Blueprints
    class DraftTaskBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :title, :description, :note, :state, :points, :due_on, :scheduled_for, :visibility,
             :ready_at, :sent_at, :created_at, :updated_at

      field :list_id, &:to_s
      field :author_id, &:to_s
      field :author_name do |draft|
        draft.author.display_name
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
      field :reserved_points, &:reserved_points
      field :editable, &:editable?
    end
  end
end
