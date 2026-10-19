module Connectors
  Page = Struct.new(:items, :next_cursor, keyword_init: true) do
    def self.empty
      new(items: [], next_cursor: nil)
    end

    def last?
      next_cursor.blank?
    end

    def size
      items.size
    end
  end
end
