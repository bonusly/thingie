class RedisLock
  RELEASE_SCRIPT = <<~LUA
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    end
    return 0
  LUA

  attr_reader :key, :ttl

  def initialize(key, ttl:)
    @key = key
    @ttl = ttl
    @token = TokenGenerator.hex(16)
  end

  def acquire
    AppRedis.with { |redis| redis.set(key, token, nx: true, ex: ttl) } == true
  end

  def release
    AppRedis.with { |redis| redis.eval(RELEASE_SCRIPT, keys: [key], argv: [token]) }.to_i.positive?
  end

  def held?
    AppRedis.with { |redis| redis.get(key) } == token
  end

  private

  attr_reader :token
end
