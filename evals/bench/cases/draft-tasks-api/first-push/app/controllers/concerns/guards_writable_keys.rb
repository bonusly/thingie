module GuardsWritableKeys
  extend ActiveSupport::Concern

  READ_ONLY_KEYS = %w[state author_id points_reserved_at].freeze

  private

  def guard_writable_keys!(attrs)
    present = READ_ONLY_KEYS & attrs.keys.map(&:to_s)
    raise DraftTasks::ReadOnlyKeys, present if present.any?
  end
end
