# frozen_string_literal: true

# Verifying doubles for ruby_llm objects whose shape differs between 1.16 and
# 2.x, so the same specs run against either bundle (see Thingie::LlmCompat).
module LlmDoubles
  TOKEN_KEYS = {
    input_tokens: :input,
    output_tokens: :output,
    cache_read_tokens: :cache_read,
    cache_write_tokens: :cache_write,
    thinking_tokens: :thinking
  }.freeze

  # An instance_double(RubyLLM::Message) that takes 1.16-style token keys. On
  # 2.x they become a RubyLLM::Tokens on #tokens.
  #
  #   message_double(content: 'hi', input_tokens: 100, output_tokens: 50)
  def message_double(**attrs)
    return instance_double(RubyLLM::Message, **attrs) unless RubyLLM::Message.method_defined?(:tokens)

    counts = attrs.slice(*TOKEN_KEYS.keys).transform_keys(TOKEN_KEYS)
    instance_double(RubyLLM::Message, tokens: RubyLLM::Tokens.new(**counts), **attrs.except(*TOKEN_KEYS.keys))
  end

  # The class RubyLLM::Message#model_info returns: Model::Info on 1.16, Model on 2.x.
  def model_info_class
    defined?(RubyLLM::Model::Info) ? RubyLLM::Model::Info : RubyLLM::Model
  end
end

RSpec.configure do |config|
  config.include LlmDoubles
end
