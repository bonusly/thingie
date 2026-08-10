# frozen_string_literal: true

require 'json'

module Thingie
  # Extracts JSON from LLM response content that may include reasoning prose
  # before or around the JSON payload. Some models return their chain-of-thought
  # as the content string instead of pure JSON, especially when they don't
  # fully respect structured output schemas.
  class JsonExtractor
    # Parses a content string as JSON, falling back to extracting the first
    # JSON object or array from surrounding prose.
    #
    # @param content [String] the raw content string from the LLM response
    # @return [Object, nil] the parsed JSON, or nil if no JSON was found
    def self.parse(content)
      JSON.parse(content)
    rescue JSON::ParserError
      extract_json(content)
    end

    # Extracts the first JSON object or array embedded in a prose string by
    # scanning for balanced braces/brackets. Returns nil if none is found.
    #
    # @param text [String] the raw content string that failed direct JSON.parse
    # @return [Object, nil] the extracted and parsed JSON, or nil
    def self.extract_json(text)
      ['{', '['].each do |open_char|
        close_char = open_char == '{' ? '}' : ']'
        extracted = extract_balanced(text, open_char, close_char)
        return JSON.parse(extracted) if extracted
      end
      nil
    rescue JSON::ParserError
      nil
    end

    # Scans text for the first balanced occurrence of open_char..close_char,
    # respecting string literals and escape sequences. Returns the matched
    # substring (including delimiters) or nil.
    #
    # @param text [String] the text to scan
    # @param open_char [String] the opening delimiter ('{' or '[')
    # @param close_char [String] the closing delimiter ('}' or ']')
    # @return [String, nil] the balanced substring, or nil
    def self.extract_balanced(text, open_char, close_char)
      start = text.index(open_char)
      return nil unless start

      depth = 0
      in_string = false
      escaped = false
      text.each_char.with_index do |ch, i|
        next if i < start

        if escaped
          escaped = false
          next
        end

        escaped = true if ch == '\\' && in_string
        next if escaped

        in_string = !in_string if ch == '"'
        next if in_string

        depth += 1 if ch == open_char
        depth -= 1 if ch == close_char
        return text[start..i] if depth.zero? && i > start
      end
      nil
    end
  end
end
