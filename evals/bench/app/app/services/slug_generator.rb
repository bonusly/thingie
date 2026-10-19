class SlugGenerator
  MAX_ATTEMPTS = 50

  def self.unique(base, &taken)
    new(base).unique(&taken)
  end

  def initialize(base)
    @base = base.presence || "item"
  end

  def unique
    return base unless yield(base)

    (2..MAX_ATTEMPTS).each do |suffix|
      candidate = "#{base}-#{suffix}"
      return candidate unless yield(candidate)
    end

    "#{base}-#{TokenGenerator.hex(4)}"
  end

  private

  attr_reader :base
end
