module Api
  module V1
    module Lists
      class ShareLinksController < BaseController
        def index
          authorize!(list, :share?)
          links = list.share_links.active.order(created_at: :desc)
          render json: links.map { |link| serialize(link) }
        end

        def create
          authorize!(list, :share?)
          result = Sharing::Commands::CreateShareLink.call(
            list: list, actor: current_user, ttl: ttl, show_drafts: params[:show_drafts] == "true"
          )
          return render_failure(result.error) if result.failure?

          render json: serialize(result.value), status: :created
        end

        def destroy
          link = list.share_links.find(params[:id])
          authorize!(link, :destroy?)
          head_result(Sharing::Commands::RevokeShareLink.call(share_link: link, actor: current_user))
        end

        private

        def list
          @list ||= ::Lists::Queries::FindList.call(company: current_company, id: params[:list_id])
        end

        def ttl
          params[:ttl_days].present? ? params[:ttl_days].to_i.clamp(1, 365).days : nil
        end

        def serialize(link)
          {
            id: link.id.to_s,
            token: link.token,
            url: share_page_url(link.token),
            expires_at: link.expires_at,
            show_drafts: link.show_drafts,
            view_count: link.view_count
          }
        end
      end
    end
  end
end
