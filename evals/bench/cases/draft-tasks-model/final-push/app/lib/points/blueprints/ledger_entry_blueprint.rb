module Points
  module Blueprints
    class LedgerEntryBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :amount, :kind, :week_key, :note, :created_at

      field :task_id do |entry|
        entry.task_id&.to_s
      end
      field :draft_task_id do |entry|
        entry.draft_task_id&.to_s
      end
      field :task_title do |entry|
        entry.task&.title
      end
      field :signed_amount, &:signed_amount
      field :from_draft, &:from_draft?
      field :label do |entry|
        I18n.t("points.ledger.kinds.#{entry.kind}", default: entry.kind)
      end
    end
  end
end
