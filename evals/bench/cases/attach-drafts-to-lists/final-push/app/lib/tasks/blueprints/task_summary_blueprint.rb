module Tasks
  module Blueprints
    class TaskSummaryBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :title, :state, :due_on, :points

      field :list_id, &:to_s
      field :author_name do |task|
        task.author.display_name
      end
      field :assignee_count do |task|
        task.assignee_ids.size
      end
      field :label_count do |task|
        task.label_ids.size
      end
      field :rewarded, &:rewarded?
    end
  end
end
