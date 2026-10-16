module Search
  module Blueprints
    class RouteBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :path, :name, :component, :permission, :indexed_at

      field :gated, &:gated?
      field :permission_label do |entry|
        entry.gated? ? I18n.t("permissions.#{entry.permission}", default: entry.permission) : nil
      end
      field :dynamic do |entry|
        entry.path.include?(":")
      end
    end
  end
end
