module Api
  module V1
    class BaseController < ApplicationController
      include AuthenticatesRequests
      include CurrentCompany
      include Paginates
      include Authorizes

      private

      def render_result(result, blueprint:, status: :ok, view: :default)
        return render_failure(result.error) if result.failure?

        render json: blueprint.render(result.value, view: view), status: status
      end

      def render_failure(error)
        raise error if error.is_a?(Exception)

        messages = Array(error)
        render json: { error: { code: "unprocessable_entity", message: messages.first, details: messages } },
               status: :unprocessable_entity
      end

      def head_result(result, status: :no_content)
        return render_failure(result.error) if result.failure?

        head status
      end
    end
  end
end
