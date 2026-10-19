class TokenGenerator
  def self.urlsafe(length = 24)
    SecureRandom.urlsafe_base64(length).tr("-_", "ab")[0, length]
  end

  def self.hex(bytes = 16)
    SecureRandom.hex(bytes)
  end

  def self.numeric(digits = 6)
    SecureRandom.random_number(10**digits).to_s.rjust(digits, "0")
  end

  def self.secure_compare(left, right)
    return false if left.nil? || right.nil?

    ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
  end
end
