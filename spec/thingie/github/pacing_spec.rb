# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'faraday'

RSpec.describe Thingie::GitHub::Pacing do # rubocop:disable RSpec/SpecFilePathFormat
  def octokit_error(klass, message, headers = {})
    klass.new(
      method: :post,
      url: 'https://api.github.com/repos/o/r/pulls/1/comments',
      status: 422,
      body: JSON.generate({ message: message }),
      response_headers: { 'content-type' => 'application/json' }.merge(headers)
    )
  end

  describe '.pacing_error?' do
    it 'retries a 422 that GitHub says arrived too quickly' do
      error = octokit_error(Octokit::UnprocessableEntity, 'Validation Failed: was submitted too quickly')
      expect(described_class.pacing_error?(nil, error)).to be true
    end

    it 'does not retry a 422 for a line outside the diff' do
      error = octokit_error(Octokit::UnprocessableEntity, 'pull_request_review_thread.line must be part of the diff')
      expect(described_class.pacing_error?(nil, error)).to be false
    end

    it 'retries a secondary rate limit unconditionally' do
      error = octokit_error(Octokit::TooManyRequests, 'You have exceeded a secondary rate limit')
      expect(described_class.pacing_error?(nil, error)).to be true
    end

    it 'retries abuse detection unconditionally' do
      error = octokit_error(Octokit::AbuseDetected, 'You have triggered an abuse detection mechanism')
      expect(described_class.pacing_error?(nil, error)).to be true
    end

    it 'does not retry an ordinary forbidden' do
      error = octokit_error(Octokit::Forbidden, 'Resource not accessible by integration')
      expect(described_class.pacing_error?(nil, error)).to be false
    end

    it 'does not retry a non-Octokit error' do
      expect(described_class.pacing_error?(nil, ArgumentError.new('bad'))).to be false
    end
  end

  describe '.parse_and_clamp_retry_after' do
    it 'parses a bare number of seconds' do
      expect(described_class.parse_and_clamp_retry_after('7')).to eq(7.0)
    end

    it 'parses an RFC 2822 date' do
      future = (Time.now.utc + 5).httpdate
      expect(described_class.parse_and_clamp_retry_after(future)).to be_within(1.0).of(5.0)
    end

    it 'clamps a value larger than MAX_DELAY_SECONDS' do
      expect(described_class.parse_and_clamp_retry_after('600')).to eq(described_class::MAX_DELAY_SECONDS)
    end

    it 'returns nil for a non-positive value' do
      expect(described_class.parse_and_clamp_retry_after('0')).to be_nil
      expect(described_class.parse_and_clamp_retry_after('-5')).to be_nil
    end

    it 'returns nil for an unparseable value' do
      expect(described_class.parse_and_clamp_retry_after('soon')).to be_nil
    end
  end

  describe '.raise_throttled' do
    it 'raises Throttled, not the original error, naming the request and attempt count' do
      env = Faraday::Env.from(method: :post, url: URI('https://api.github.com/repos/o/r/pulls/1/comments'))
      cause = octokit_error(Octokit::UnprocessableEntity, 'was submitted too quickly')

      expect { described_class.raise_throttled(env: env, exception: cause) }
        .to raise_error(described_class::Throttled) do |error|
          expect(error).not_to be_a(Octokit::Error)
          expect(error.cause_error).to be(cause)
          expect(error.message).to include('POST /repos/o/r/pulls/1/comments')
          expect(error.message).to include("after #{described_class::MAX_ATTEMPTS} attempts")
        end
    end
  end

  describe '.middleware, driven end to end through a real Faraday stack' do
    # Faraday::Adapter::Test rather than a real connection, driving the
    # middleware exactly as Octokit::Client builds it — a unit test of
    # pacing_error? or raise_throttled in isolation would not catch a wiring
    # mistake in how they're plugged into Faraday::RackBuilder.
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }

    def build_client
      Octokit::Client.new(access_token: 'token', middleware: described_class.middleware(adapter: [:test, stubs]))
    end

    # Every backoff/Retry-After wait in these examples is real unless stubbed;
    # keep them fast and assert on what was asked for, not on wall-clock time.
    before { allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) } # rubocop:disable RSpec/AnyInstance

    it 'retries a too-quickly 422 and succeeds once GitHub accepts it' do
      calls = 0
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        calls < 3 ? [422, {}, '{"message":"Validation Failed: was submitted too quickly"}'] : [201, {}, '{}']
      end

      build_client.post('/repos/o/r/pulls/1/comments', {})

      expect(calls).to eq(3)
      stubs.verify_stubbed_calls
    end

    it 'does not retry an off-diff 422 and raises immediately, on the first attempt' do
      calls = 0
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        [422, {}, '{"message":"pull_request_review_thread.line must be part of the diff"}']
      end

      expect { build_client.post('/repos/o/r/pulls/1/comments', {}) }.to raise_error(Octokit::UnprocessableEntity)
      expect(calls).to eq(1)
    end

    it 'raises Throttled, not Octokit::UnprocessableEntity, once every attempt is refused' do
      calls = 0
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        [422, {}, '{"message":"Validation Failed: was submitted too quickly"}']
      end

      expect { build_client.post('/repos/o/r/pulls/1/comments', {}) }
        .to raise_error(described_class::Throttled) { |error| expect(error.cause_error).to be_a(Octokit::UnprocessableEntity) }
      expect(calls).to eq(described_class::MAX_ATTEMPTS)
    end

    it 'retries a secondary rate limit through to success' do
      calls = 0
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        calls < 2 ? [403, {}, '{"message":"You have exceeded a secondary rate limit"}'] : [201, {}, '{}']
      end

      build_client.post('/repos/o/r/pulls/1/comments', {})

      expect(calls).to eq(2)
    end

    it 'honors a Retry-After header rather than its own backoff schedule' do
      waited = nil
      allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) { |_, seconds| waited = seconds } # rubocop:disable RSpec/AnyInstance
      calls = 0
      body = '{"message":"You have exceeded a secondary rate limit"}'
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        calls < 2 ? [403, { 'Retry-After' => '3' }, body] : [201, {}, '{}']
      end

      build_client.post('/repos/o/r/pulls/1/comments', {})

      expect(waited).to eq(3.0)
    end

    it 'never lets a runaway Retry-After header bypass Throttled' do
      # Without the clamp in parse_and_clamp_retry_after, Faraday::Retry treats
      # a Retry-After past max_interval as "give up silently" and re-raises the
      # original Octokit error instead of routing through exhausted_retries_block.
      stubs.post('/repos/o/r/pulls/1/comments') do
        [403, { 'Retry-After' => '99999' }, '{"message":"You have exceeded a secondary rate limit"}']
      end

      expect { build_client.post('/repos/o/r/pulls/1/comments', {}) }.to raise_error(described_class::Throttled)
    end
  end
end
