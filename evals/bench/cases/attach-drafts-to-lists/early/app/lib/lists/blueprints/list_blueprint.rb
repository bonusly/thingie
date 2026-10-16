module Lists
  module Blueprints
    class ListBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :name, :slug, :description, :state, :visibility, :position, :delivered_at, :created_at, :updated_at

      field :owner_id, &:to_s
      field :member_ids do |list|
        list.member_ids.map(&:to_s)
      end

      view :with_counts do
        field :open_task_count do |list|
          list.tasks.open.count
        end
        field :ready_draft_count do |list|
          list.draft_tasks.ready.count
        end
        field :attached_draft_count do |list|
          list.draft_tasks.attached.not_sent.count
        end
        field :member_count do |list|
          list.members.count
        end
      end
    end
  end
end
