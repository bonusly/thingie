module Connectors
  module Blueprints
    class ExternalItemBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :provider, :external_id, :kind, :title, :url, :external_updated_at

      field :connector_account_id, &:to_s
      field :imported_task_id do |item|
        item.imported_task_id&.to_s
      end
      field :imported, &:imported?
    end
  end
end
