Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("CORS_ORIGINS", "http://localhost:5173").split(",")
    resource "/api/*",
             headers: :any,
             methods: %i[get post put patch delete options head],
             expose: %w[X-Total-Count X-Next-Cursor],
             credentials: true
  end

  allow do
    origins "*"
    resource "/s/*", headers: :any, methods: %i[get options head]
  end
end
