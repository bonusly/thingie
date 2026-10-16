class ApplicationController < ActionController::API
  include HandlesErrors

  before_action :set_locale

  private

  def set_locale
    requested = request.headers["Accept-Language"].to_s.scan(/[a-z]{2}/).first
    I18n.locale = I18n.available_locales.map(&:to_s).include?(requested) ? requested : I18n.default_locale
  end

  def request_ip
    request.remote_ip
  end

  def default_url_options
    { host: ENV.fetch("APP_HOST", "localhost:3000") }
  end
end
