module Connectors
  module Blueprints
    class ConnectorAccountBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :provider, :external_account_id, :external_account_name, :state, :last_synced_at, :last_error, :created_at

      field :user_id, &:to_s
      field :item_count do |account|
        account.external_items.count
      end
      field :unimported_count do |account|
        account.external_items.unimported.count
      end
      field :has_cursor do |account|
        account.cursor.present?
      end
    end
  end
end
