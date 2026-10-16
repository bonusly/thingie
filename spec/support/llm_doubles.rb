# frozen_string_literal: true

# Verifying doubles for ruby_llm objects, so the many spec call sites stay short.
module LlmDoubles
  TOKEN_KEYS = {
    input_tokens: :input,
    output_tokens: :output,
    cache_read_tokens: :cache_read,
    cache_write_tokens: :cache_write,
    thinking_tokens: :thinking
  }.freeze

  # An instance_double(RubyLLM::Message) that takes flat token keys and turns them into a RubyLLM::Tokens.
  #
  #   message_double(content: 'hi', input_tokens: 100, output_tokens: 50)
  def message_double(**attrs)
    counts = attrs.slice(*TOKEN_KEYS.keys).transform_keys(TOKEN_KEYS)
    instance_double(RubyLLM::Message, tokens: RubyLLM::Tokens.new(**counts), **attrs.except(*TOKEN_KEYS.keys))
  end
end

RSpec.configure do |config|
  config.include LlmDoubles
end
