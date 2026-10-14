# frozen_string_literal: true

module Thingie
  module GitHub
    # Reads line numbers out of the unified diff GitHub gives for a file.
    module DiffLines
      HUNK_HEADER = /^@@ -\d+(?:,\d+)? \+(\d+)/

      module_function

      # The new-side line numbers a patch covers: added and context lines, or only added ones. Hunk
      # headers, deletions and "\\ No newline" markers neither advance nor anchor a line number.
      #
      # @param patch [String] the unified diff of one file
      # @param added_only [Boolean] leave out the unchanged context lines
      # @return [Set<Integer>] the new-side line numbers
      def new_side(patch, added_only: false)
        lines = Set.new
        new_line = nil
        patch.each_line do |raw|
          line = raw.chomp
          if (match = line.match(HUNK_HEADER))
            new_line = match[1].to_i
          elsif new_line.nil? || line.start_with?('\\', '-')
            next
          else
            lines << new_line unless added_only && !line.start_with?('+')
            new_line += 1
          end
        end
        lines
      end
    end
  end
end
