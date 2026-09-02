# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::ObfuscationDetector do
  subject(:detector) { described_class.new(changeset) }

  # 80+ hex chars, over the HEX_BLOB detection threshold.
  let(:hex_payload) do
    '4142434445464748494a4b4c4d4e4f505152535455565758595a6162636465666768696a6b6c6d6e6f70'
  end

  let(:files) { ['app.rb'] }

  let(:changeset) do
    instance_double(Thingie::Changeset, files: files, full_content_for: content)
  end

  let(:content) { 'def hello; end' }

  def issues_for_content(file_content)
    described_class.new(
      instance_double(Thingie::Changeset,
                      files: ['app.rb'],
                      full_content_for: file_content)
    ).call
  end

  describe 'clean code' do
    it 'finds nothing on ordinary code' do
      content = "def add(a, b)\n  a + b\nend\n"
      expect(issues_for_content(content)).to be_empty
    end

    it 'ignores ordinary metaprogramming' do
      code = "object.send(:method_name)\ndefine_method(:foo) { nil }\n"
      expect(issues_for_content(code)).to be_empty
    end

    it 'ignores short hex strings such as colors and SHA fragments' do
      code = "COLOR = '#ff0000'\nOID = 'd41d8cd98f00b204e9800998ecf8427e'\n"
      expect(issues_for_content(code)).to be_empty
    end

    it 'blocks readable eval of a plain literal too (any eval requires review)' do
      code = "instance_eval('2 + 2')\n"
      expect(issues_for_content(code).first.title).to include('dynamic code execution')
    end

    it 'still ignores ordinary send with a non-eval method name' do
      code = "object.send(:method_name)\n"
      expect(issues_for_content(code)).to be_empty
    end

    it 'ignores sparse escape sequences in ordinary strings' do
      code = "path = 'C:\\new\\table'\nregex = /\\d+\\.\\d+/\n"
      expect(issues_for_content(code)).to be_empty
    end

    it 'ignores words under the blob threshold' do
      code = "word = 'a' * 99\n"
      expect(issues_for_content(code)).to be_empty
    end

    it 'ignores one or two .chr conversions' do
      code = "separator = 10.chr\n"
      expect(issues_for_content(code)).to be_empty
    end
  end

  describe 'detection signals' do
    it 'flags a long hex blob' do
      code = "payload = '#{hex_payload}'\n"
      issues = issues_for_content(code)
      expect(issues.size).to eq(1)
      expect(issues.first.title).to include('hex-encoded blob')
      expect(issues.first.severity).to eq(1)
      expect(issues.first.tags).to contain_exactly('security', 'obfuscation')
      expect(issues.first.affected_lines.first.start_line).to eq(1)
    end

    it 'flags a long base64 blob' do
      b64 = 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0NTY3ODlhYmNE' \
            'RUZHSElKS0xNTk9QUVJTVFVWV1hZWg=='
      code = "data = '#{b64}'\n"
      issues = issues_for_content(code)
      expect(issues.size).to eq(1)
      expect(issues.first.title).to include('base64-encoded blob')
    end

    it 'flags eval of decoded base64' do
      code = "eval(Base64.decode64('encoded_payload'))\n"
      issues = issues_for_content(code)
      expect(issues.size).to eq(1)
      expect(issues.first.title).to include('dynamic code execution')
    end

    it 'flags eval of a payload decoded on a previous line' do
      code = "payload = Base64.decode64(encoded)\neval(payload)\n"
      issues = issues_for_content(code)
      expect(issues.size).to eq(1)
      expect(issues.first.title).to include('dynamic code execution')
      expect(issues.first.affected_lines.first.start_line).to eq(2)
    end

    it 'flags indirect eval invocation via send/public_send/method' do
      invocations = [
        'send(:eval, code)',
        'public_send(:eval, code)',
        '__send__("eval", code)',
        "send('eval', code)",
        'method(:eval).call(code)'
      ]
      invocations.each do |invocation|
        expect(issues_for_content("#{invocation}\n").first.title).to include('dynamic code execution'),
                                                                     "expected #{invocation} to be flagged"
      end
    end

    it 'flags eval of a payload built from concatenated strings' do
      code = "s = '41' + '42' + '43'\neval(s)\n"
      issues = issues_for_content(code)
      expect(issues.size).to eq(1)
      expect(issues.first.title).to include('dynamic code execution')
    end

    it 'flags eval of a payload built with pack' do
      code = "s = [109, 97].pack('C*')\neval(s)\n"
      expect(issues_for_content(code).map(&:title).join).to include('dynamic code execution')
    end

    it 'flags String.fromCharCode construction' do
      code = "var s = String.fromCharCode(104, 101, 108, 108, 111);\n"
      issues = issues_for_content(code)
      expect(issues.size).to eq(1)
      expect(issues.first.title).to include('character codes')
    end

    it 'flags lowercase pack c* and unicode pack U* variants' do
      ["payload = [109, 97].pack('c*')", "payload = [109, 97].pack('U*')"].each do |line|
        expect(issues_for_content("#{line}\n").first.title).to include('character codes'),
                                                               "expected #{line} to be flagged"
      end
    end

    it 'flags pack C* byte-array string construction' do
      code = "payload = [109, 97, 108, 105, 99, 105, 111, 117, 115].pack('C*')\n"
      expect(issues_for_content(code).first.title).to include('character codes')
    end

    it 'flags three or more .chr literals in one line' do
      code = 's = 104.chr + 101.chr + 108.chr'
      expect(issues_for_content(code).first.title).to include('character codes')
    end

    describe 'blob thresholds' do
      it 'flags a hex blob at exactly 80 chars' do
        expect(issues_for_content("p = '#{'f' * 80}'\n").size).to eq(1)
      end

      it 'ignores a hex run of 79 chars' do
        expect(issues_for_content("p = '#{'f' * 79}'\n")).to be_empty
      end

      it 'flags a base64 blob at exactly 100 chars' do
        expect(issues_for_content("p = '#{'z' * 100}'\n").size).to eq(1)
      end

      it 'ignores a base64 run of 99 chars' do
        expect(issues_for_content("p = '#{'z' * 99}'\n")).to be_empty
      end
    end

    it 'flags escape runs split across literals when followed by eval' do
      code = "data = \"\\x41\\x42\\x43\\x44\" + \"\\x45\\x46\\x47\\x48\"\neval(data)\n"
      expect(issues_for_content(code).map(&:title).join).to include('dynamic code execution')
    end

    it 'flags a dense \x hex escape run' do
      code = 'data = "\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a"'
      expect(issues_for_content(code).first.title).to include('escape sequences')
    end

    it 'flags a dense \u escape run' do
      code = 'data = "\u0041\u0042\u0043\u0044\u0045\u0046\u0047\u0048\u0049\u004a\u004b"'
      expect(issues_for_content(code).first.title).to include('escape sequences')
    end
  end

  describe 'comments' do
    it 'ignores the word eval in a Ruby comment' do
      code = "# GitHub Observed Moments — SCORED eval (LLM judge, pass/fail).\n"
      expect(issues_for_content(code)).to be_empty
    end

    it 'ignores example code quoted in a comment' do
      code = "# Ruby byte-array-to-string construction: `[65, 66].pack('C*')`.\n" \
             "# JavaScript `String.fromCharCode(72, 101, 108)`.\n"
      expect(issues_for_content(code)).to be_empty
    end

    it 'ignores an eval mentioned in a JavaScript comment' do
      code = "// use indirect eval (which violates Content Security Policy).\n"
      expect(issues_for_content(code)).to be_empty
    end

    it 'still flags real code that carries a trailing comment' do
      code = "eval(payload) # decoded above\n"
      expect(issues_for_content(code).first.title).to include('dynamic code execution')
    end

    it 'does not treat a hash inside a string literal as a comment' do
      code = "label = '#not-a-comment'\ninstance_eval(payload)\n"
      expect(issues_for_content(code).first.title).to include('dynamic code execution')
    end

    it 'does not treat the slashes in a URL as a comment' do
      code = %(fetch('http://example.com') && eval(payload)\n)
      expect(issues_for_content(code).first.title).to include('dynamic code execution')
    end

    it 'still flags an encoded blob sitting in a comment' do
      code = "# leftover payload #{hex_payload}\n"
      expect(issues_for_content(code).first.title).to include('hex-encoded blob')
    end

    it 'does not flag its own documentation' do
      source = File.read(File.expand_path('../../lib/thingie/obfuscation_detector.rb', __dir__))
      expect(issues_for_content(source)).to be_empty
    end
  end

  describe 'matching behavior' do
    it 'caps matches per file' do
      code = (1..10).map { |i| "line#{i} = '#{hex_payload}#{i}'" }.join("\n")
      expect(issues_for_content(code).size).to eq(5)
    end

    it 'reports the correct line number' do
      code = "def clean\nend\npayload = '#{hex_payload}'\n"
      expect(issues_for_content(code).first.affected_lines.first.start_line).to eq(3)
    end

    it 'produces one issue per line even when multiple signals match' do
      code = "eval(Base64.decode64('#{hex_payload}'))\n"
      expect(issues_for_content(code).size).to eq(1)
    end

    it 'skips binary files with nil content' do
      changeset = instance_double(Thingie::Changeset, files: ['app.rb', 'image.png'])
      allow(changeset).to receive(:full_content_for).with('app.rb').and_return("puts 'ok'\n")
      allow(changeset).to receive(:full_content_for).with('image.png').and_return(nil)

      expect(described_class.new(changeset).call).to be_empty
    end

    it 'returns issues without ids so Reviewer can assign them' do
      code = "payload = '#{hex_payload}'\n"
      expect(issues_for_content(code).first.id).to be_nil
    end

    it 'round-trips through Issue JSON serialization' do
      code = "payload = '#{hex_payload}'\n"
      issue = issues_for_content(code).first
      restored = Thingie::Issue.from_hash(JSON.parse(JSON.generate(issue.to_h)))
      expect(restored.title).to eq(issue.title)
      expect(restored.tags).to eq(%w[security obfuscation])
      expect(restored.severity).to eq(1)
    end
  end
end
