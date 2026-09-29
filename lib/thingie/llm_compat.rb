# frozen_string_literal: true

module Thingie
  # Reads the parts of the ruby_llm API that differ between 1.16 and 2.x, so
  # thingie runs in a bundle pinned to either. Remove once every consumer is
  # on 2.x.
  #
  #   1.16                      2.x
  #   param :path, desc: ...    parameter :path, description: ...
  #   message.input_tokens      message.tokens.input
  #   models.refresh!           models.refresh
  #   models.load_from_json!    models.load_from_json
  module LlmCompat
    TOKEN_KINDS = {
      input_tokens: :input,
      output_tokens: :output,
      cache_read_tokens: :cache_read,
      cache_write_tokens: :cache_write,
      thinking_tokens: :thinking
    }.freeze

    module_function

    # Declares a tool argument on `tool_class`.
    #
    # @param tool_class [Class] a RubyLLM::Tool subclass
    # @param name [Symbol] the argument name
    # @param description [String] what the model should pass
    # @param options [Hash] other parameter options, e.g. required:
    def parameter(tool_class, name, description:, **options)
      if tool_class.respond_to?(:parameter)
        tool_class.parameter(name, description: description, **options)
      else
        tool_class.param(name, description: description, **options)
      end
    end

    # @param response [Object, nil] a RubyLLM::Message
    # @param kind [Symbol] one of TOKEN_KINDS' keys, e.g. :input_tokens
    # @return [Integer, nil] the count, or nil when the provider didn't report it
    def tokens(response, kind)
      return nil if response.nil?

      if response.respond_to?(:tokens)
        response.tokens&.public_send(TOKEN_KINDS.fetch(kind))
      elsif response.respond_to?(kind)
        response.public_send(kind)
      end
    end

    # Refreshes the model registry from the configured providers.
    #
    # @param models [RubyLLM::Models] the registry to refresh
    def refresh_models(models = RubyLLM.models)
      models.respond_to?(:refresh!) ? models.refresh! : models.refresh
    end

    # Loads the model registry from a JSON file.
    #
    # @param path [String] the registry JSON file
    # @param models [RubyLLM::Models] the registry to load into
    def load_models_from_json(path, models = RubyLLM.models)
      models.respond_to?(:load_from_json!) ? models.load_from_json!(path) : models.load_from_json(path)
    end
  end
end
