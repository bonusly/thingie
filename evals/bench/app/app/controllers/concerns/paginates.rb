module Paginates
  extend ActiveSupport::Concern

  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  def page
    [params[:page].to_i, 1].max
  end

  def per_page
    (params[:per_page].presence || DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
  end

  def paginate(scope)
    total = scope.count
    response.set_header("X-Total-Count", total.to_s)
    response.set_header("X-Next-Cursor", (page + 1).to_s) if page * per_page < total
    scope.skip((page - 1) * per_page).limit(per_page)
  end

  def render_collection(scope, blueprint, view: :default, **options)
    records = paginate(scope)
    render json: blueprint.render(records, view: view, **options)
  end
end
