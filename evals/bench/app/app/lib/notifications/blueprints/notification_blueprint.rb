module Notifications
  module Blueprints
    class NotificationBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :kind, :subject_type, :payload, :read_at, :created_at

      field :subject_id, &:to_s
      field :read, &:read?
      field :title do |notification|
        I18n.t("notifications.kinds.#{notification.kind}", **notification.payload.symbolize_keys, default: notification.kind)
      end
    end
  end
end
