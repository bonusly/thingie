class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "Tasker <no-reply@tasker.io>")
  layout "mailer"

  helper_method :app_url

  private

  def app_url(path = "/")
    base = ENV.fetch("APP_URL", "https://app.tasker.io")
    "#{base.delete_suffix('/')}#{path}"
  end

  def with_user_locale(user, &)
    I18n.with_locale(user.locale.presence || I18n.default_locale, &)
  end
end
