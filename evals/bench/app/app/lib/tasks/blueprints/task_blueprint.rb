module Tasks
  module Blueprints
    class TaskBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :title, :description, :state, :due_on, :points, :position, :completed_at, :created_at, :updated_at

      field :list_id, &:to_s
      field :author_id, &:to_s
      field :assignee_ids do |task|
        task.assignee_ids.map(&:to_s)
      end
      field :label_ids do |task|
        task.label_ids.map(&:to_s)
      end
      field :overdue do |task, options|
        task.overdue?(today: options.fetch(:today, Date.current))
      end

      view :detailed do
        field :comment_count do |task|
          task.comments.count
        end
        field :attachment_count do |task|
          task.attachments.count
        end
        association :attachments, blueprint: Tasks::Blueprints::AttachmentBlueprint
      end
    end
  end
end
