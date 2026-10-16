module Public
  class SharePagesController < ApplicationController
    CACHE_TTL = 1.minute

    def show
      link = Sharing::Queries::ResolveShareLink.call(token: params[:token])
      link.record_view!
      view = Sharing::Queries::PublicList.call(share_link: link)

      expires_in CACHE_TTL, public: true
      response.set_header("X-Robots-Tag", "noindex")
      render json: Sharing::Blueprints::PublicListBlueprint.render(view)
    end
  end
end
