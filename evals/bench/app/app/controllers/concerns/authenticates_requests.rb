module AuthenticatesRequests
  extend ActiveSupport::Concern

  class Unauthenticated < StandardError; end

  BEARER = /\ABearer\s+(?<token>\S+)\z/

  included do
    before_action :authenticate!
    attr_reader :current_user, :current_api_key
  end

  private

  def authenticate!
    key = ApiKey.authenticate(bearer_token)
    raise Unauthenticated if key.nil? || !key.company.active?

    key.touch_used!
    @current_api_key = key
    @current_user = key.user
    current_user.touch_seen!
  end

  def bearer_token
    match = BEARER.match(request.authorization.to_s)
    match && match[:token]
  end
end
