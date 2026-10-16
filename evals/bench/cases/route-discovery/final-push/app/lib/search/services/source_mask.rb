module Search
  module Services
    class SourceMask
      QUOTES = ['"', "'"].freeze

      def self.call(source)
        new(source).call
      end

      def initialize(source)
        @chars = source.chars
        @masked = source.dup
      end

      def call
        index = 0
        while index < chars.size
          char = chars[index]
          index = if QUOTES.include?(char)
                    mask_string(index, char)
                  elsif char == "`"
                    mask_template(index)
                  else
                    index + 1
                  end
        end
        masked
      end

      private

      attr_reader :chars, :masked

      def mask_string(start, quote)
        stop = start + 1
        while stop < chars.size && chars[stop] != quote
          stop += 1 if chars[stop] == "\\"
          stop += 1
        end
        blank(start + 1, stop)
        stop + 1
      end

      def mask_template(start)
        depth = 0
        stop = start + 1
        while stop < chars.size
          if chars[stop, 2].join == "${"
            depth += 1
            stop += 2
            next
          end
          depth -= 1 if chars[stop] == "}" && depth.positive?
          break if chars[stop] == "`" && depth.zero?

          stop += 1
        end
        blank(start + 1, stop)
        stop + 1
      end

      def blank(from, to)
        masked[from...to] = "#" * (to - from) if to > from
      end
    end
  end
end
