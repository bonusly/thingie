class NotificationMailer < ApplicationMailer
  def single(notification)
    @notification = notification
    @user = notification.recipient
    @title = title_for(notification)
    @notifications_url = app_url("/notifications")

    with_user_locale(@user) do
      mail(to: @user.email, subject: @title)
    end
  end

  private

  def title_for(notification)
    I18n.t("notifications.kinds.#{notification.kind}", **notification.payload.symbolize_keys, default: notification.kind)
  end
end
