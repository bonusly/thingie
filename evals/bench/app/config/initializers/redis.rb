module AppRedis
  def self.pool
    @pool ||= ConnectionPool.new(size: ENV.fetch("REDIS_POOL_SIZE", 5).to_i, timeout: 2) do
      Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    end
  end

  def self.with(&)
    pool.with(&)
  end

  def self.healthy?
    with { |redis| redis.ping == "PONG" }
  rescue Redis::BaseError
    false
  end
end
