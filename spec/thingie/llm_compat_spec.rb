# frozen_string_literal: true

RSpec.describe Thingie::LlmCompat do
  describe '.parameter' do
    it 'declares the argument with the bundled ruby_llm DSL' do
      tool_class = Class.new(RubyLLM::Tool) do
        description 'compat demo'
        Thingie::LlmCompat.parameter(self, :path, description: 'a path', required: true)
      end

      declared = tool_class.respond_to?(:declared_parameters) ? tool_class.declared_parameters : tool_class.parameters
      expect(declared.fetch(:path).description).to eq('a path')
    end
  end

  describe '.tokens' do
    it 'reads 2.x counts from message.tokens' do
      tokens = Struct.new(:input, :output, :cache_read, :cache_write, :thinking).new(10, 5, 2, 1, 3)
      response = Struct.new(:tokens).new(tokens)

      expect(described_class.tokens(response, :input_tokens)).to eq(10)
      expect(described_class.tokens(response, :cache_read_tokens)).to eq(2)
      expect(described_class.tokens(response, :thinking_tokens)).to eq(3)
    end

    it 'prefers the 1.16 readers over the 1.16 #tokens shape' do
      response = Struct.new(:input_tokens, :tokens).new(10, Object.new)

      expect(described_class.tokens(response, :input_tokens)).to eq(10)
    end

    it 'reads 1.16 counts from the message readers' do
      response = Struct.new(:input_tokens, :output_tokens).new(10, 5)

      expect(described_class.tokens(response, :input_tokens)).to eq(10)
      expect(described_class.tokens(response, :output_tokens)).to eq(5)
    end

    it 'is nil without a response' do
      expect(described_class.tokens(nil, :input_tokens)).to be_nil
    end
  end

  describe '.refresh_models' do
    it 'calls refresh! on 1.16' do
      models = double(refresh!: :refreshed)

      expect(described_class.refresh_models(models)).to eq(:refreshed)
    end

    it 'calls refresh on 2.x' do
      models = double(refresh: :refreshed)

      expect(described_class.refresh_models(models)).to eq(:refreshed)
    end
  end

  describe '.load_models_from_json' do
    it 'calls load_from_json! on 1.16' do
      models = double
      allow(models).to receive(:load_from_json!).with('models.json').and_return(:loaded)

      expect(described_class.load_models_from_json('models.json', models)).to eq(:loaded)
    end

    it 'calls load_from_json on 2.x' do
      models = double
      allow(models).to receive(:load_from_json).with('models.json').and_return(:loaded)

      expect(described_class.load_models_from_json('models.json', models)).to eq(:loaded)
    end
  end

  describe '.on_tool_call' do
    let(:seen) { [] }
    let(:handler) { ->(call) { seen << call } }

    it 'hooks before_tool_call when the chat has it' do
      chat = Class.new do
        def before_tool_call(&block)
          @block = block
          self
        end

        def fire(call) = @block.call(call)
      end.new

      described_class.on_tool_call(chat, handler)
      chat.fire(:a_tool_call)

      expect(seen).to eq([:a_tool_call])
    end

    it 'falls back to on_tool_call on older ruby_llm' do
      chat = Class.new do
        def on_tool_call(&block)
          @block = block
          self
        end

        def fire(call) = @block.call(call)
      end.new

      described_class.on_tool_call(chat, handler)
      chat.fire(:a_tool_call)

      expect(seen).to eq([:a_tool_call])
    end
  end
end
