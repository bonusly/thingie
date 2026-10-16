Result = Struct.new(:success, :value, :error, keyword_init: true) do
  def self.success(value = nil)
    new(success: true, value: value, error: nil)
  end

  def self.failure(error)
    new(success: false, value: nil, error: error)
  end

  def success?
    success
  end

  def failure?
    !success
  end

  def value!
    raise error.is_a?(Exception) ? error : StandardError, error.to_s if failure?

    value
  end

  def on_success
    yield value if success?
    self
  end

  def on_failure
    yield error if failure?
    self
  end
end
