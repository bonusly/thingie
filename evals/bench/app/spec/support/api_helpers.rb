module ApiHelpers
  def auth_headers(user, company)
    _key, raw = ApiKey.generate(company: company, user: user, label: "spec")
    { "Authorization" => "Bearer #{raw}", "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  def json
    @json ||= JSON.parse(response.body)
  end

  def json_error
    json.fetch("error")
  end

  def api_get(path, user:, company:, params: {})
    get(path, params: params, headers: auth_headers(user, company))
  end

  def api_post(path, user:, company:, params: {})
    post(path, params: params.to_json, headers: auth_headers(user, company))
  end

  def api_patch(path, user:, company:, params: {})
    patch(path, params: params.to_json, headers: auth_headers(user, company))
  end

  def api_delete(path, user:, company:)
    delete(path, headers: auth_headers(user, company))
  end
end
