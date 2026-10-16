module HandlesErrors
  extend ActiveSupport::Concern

  NOT_FOUND = [
    Mongoid::Errors::DocumentNotFound, Tasks::NotFound, Lists::NotFound, DraftTasks::NotFound,
    Comments::NotFound, Notifications::NotFound, Sharing::NotFound
  ].freeze

  UNPROCESSABLE = [
    Mongoid::Errors::Validations, Connectors::InvalidInput, Points::InsufficientBalance, Points::NotAMember,
    DraftTasks::WrongState, DraftTasks::NotEditable, Tasks::InvalidTransition, Tasks::WrongCompany,
    Lists::Archived, Lists::NotAMember, Sharing::NotShareable, Admin::AlreadySuspended
  ].freeze

  FORBIDDEN = [
    ApplicationPolicy::NotAuthorized, Admin::NotStaff, CurrentCompany::NotAMember, Comments::NotAuthor
  ].freeze

  included do
    rescue_from StandardError, with: :render_internal_error
    rescue_from(*NOT_FOUND) { |error| render_error(:not_found, error) }
    rescue_from(*UNPROCESSABLE) { |error| render_error(:unprocessable_entity, error) }
    rescue_from ActionController::ParameterMissing do |error|
      render_error(:bad_request, error)
    end
    rescue_from(*FORBIDDEN) { |error| render_error(:forbidden, error) }
    rescue_from AuthenticatesRequests::Unauthenticated do |error|
      render_error(:unauthorized, error)
    end
    rescue_from DraftTasks::Services::WithLockedDraft::Lock::Busy do |error|
      render_error(:conflict, error)
    end
  end

  private

  def render_error(status, error, details: nil)
    message = error.respond_to?(:message) ? error.message : error.to_s
    body = { error: { code: status.to_s, message: message } }
    body[:error][:details] = details if details
    render json: body, status: status
  end

  def render_internal_error(error)
    Rails.logger.error("#{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}")
    raise error if Rails.env.local?

    render_error(:internal_server_error, I18n.t("errors.internal"))
  end
end
