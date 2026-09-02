# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'faraday'

RSpec.describe Thingie::GitHub::Pacing do # rubocop:disable RSpec/SpecFilePathFormat
  # Status defaults to what Octokit actually raises this class for (422 for
  # UnprocessableEntity, 403 for Forbidden/TooManyRequests/AbuseDetected), so
  # a fixture built without an explicit status stays faithful to the real
  # response shape even where pacing_error? doesn't (yet) key off it.
  def octokit_error(klass, message, status: nil, headers: {})
    status ||= klass <= Octokit::UnprocessableEntity ? 422 : 403
    klass.new(
      method: :post,
      url: 'https://api.github.com/repos/o/r/pulls/1/comments',
      status: status,
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

    it 'retries a secondary rate limit' do
      error = octokit_error(Octokit::TooManyRequests, 'You have exceeded a secondary rate limit')
      expect(described_class.pacing_error?(nil, error)).to be true
    end

    # Octokit's own Error.error_for_403 maps both messages into the same
    # Octokit::TooManyRequests class, but they mean very different things: the
    # primary limit only clears at a fixed reset time, often up to an hour
    # away — no amount of ~30s-capped retrying will outlast that.
    it 'does not retry the primary API rate limit despite sharing a class with the secondary one' do
      error = octokit_error(Octokit::TooManyRequests, 'API rate limit exceeded for user ID 123.')
      expect(described_class.pacing_error?(nil, error)).to be false
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

    # Octokit 10's Error.from_response has no dedicated branch for status 429;
    # it falls through to the generic 400..499 => Octokit::ClientError case.
    # Octokit::TooManyRequests is reachable only via a 403 body reading
    # "exceeded a secondary rate limit" (Error.error_for_403) — never from an
    # actual 429 — so a real rate-limit response needs its own check.
    it 'retries a genuine HTTP 429' do
      error = octokit_error(Octokit::ClientError, 'API rate limit exceeded', status: 429)
      expect(described_class.pacing_error?(nil, error)).to be true
    end

    it 'does not retry a ClientError for an unrelated 4xx status' do
      error = octokit_error(Octokit::ClientError, 'Conflict', status: 409)
      expect(described_class.pacing_error?(nil, error)).to be false
    end

    # Octokit::Default::MIDDLEWARE itself retries a connection-level failure
    # or 5xx on an idempotent method — replacing that stack must not drop this
    # coverage, or a transient read failure that used to self-heal now aborts
    # the run outright instead.
    def env_for(method)
      Faraday::Env.from(method: method, url: URI('https://api.github.com/repos/o/r/pulls/1'))
    end

    it 'retries a connection timeout on a GET' do
      expect(described_class.pacing_error?(env_for(:get), Faraday::TimeoutError.new)).to be true
    end

    it 'retries a 5xx on a GET' do
      error = octokit_error(Octokit::ServerError, 'Internal Server Error', status: 500)
      expect(described_class.pacing_error?(env_for(:get), error)).to be true
    end

    it 'does not retry a connection timeout on a POST, where repeating it is not safe' do
      expect(described_class.pacing_error?(env_for(:post), Faraday::TimeoutError.new)).to be false
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

    it 'does not retry the primary rate limit, raising immediately as the plain Octokit error' do
      calls = 0
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        [403, {}, '{"message":"API rate limit exceeded for user ID 123."}']
      end

      expect { build_client.post('/repos/o/r/pulls/1/comments', {}) }.to raise_error(Octokit::TooManyRequests)
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

    # The blanket `before` stub above only proves attempts happen, not that
    # they're paced correctly — interval: BASE_DELAY_SECONDS and
    # backoff_factor: 2 could regress to 0 or 1 (no pacing at all) with every
    # other example in this file still green.
    it 'doubles the wait each retry per the configured backoff schedule' do
      waited = []
      allow_any_instance_of(Faraday::Retry::Middleware) # rubocop:disable RSpec/AnyInstance
        .to receive(:sleep) { |_, seconds| waited << seconds }
      calls = 0
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        calls <= described_class::MAX_ATTEMPTS ? [422, {}, '{"message":"was submitted too quickly"}'] : [201, {}, '{}']
      end

      expect { build_client.post('/repos/o/r/pulls/1/comments', {}) }.to raise_error(described_class::Throttled)

      expect(waited).to eq([1.0, 2.0, 4.0, 8.0])
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

    it 'retries a genuine 429, raised as the untyped Octokit::ClientError, through to success' do
      calls = 0
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        calls < 2 ? [429, {}, '{"message":"API rate limit exceeded"}'] : [201, {}, '{}']
      end

      build_client.post('/repos/o/r/pulls/1/comments', {})

      expect(calls).to eq(2)
    end

    it 'honors a Retry-After header rather than its own backoff schedule' do
      waited = nil
      # The block's leading `_` is the middleware instance, not a sleep
      # argument — rspec-mocks prepends the receiver to any_instance_of
      # implementation blocks by default. `.with(kind_of(Numeric))` states
      # the actual call shape (`sleep(seconds)`) explicitly, so this doesn't
      # rely on that default going unremarked.
      allow_any_instance_of(Faraday::Retry::Middleware) # rubocop:disable RSpec/AnyInstance
        .to receive(:sleep).with(kind_of(Numeric)) { |_, seconds| waited = seconds }
      calls = 0
      body = '{"message":"You have exceeded a secondary rate limit"}'
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        calls < 2 ? [403, { 'Retry-After' => '3' }, body] : [201, {}, '{}']
      end

      build_client.post('/repos/o/r/pulls/1/comments', {})

      expect(waited).to eq(3.0)
    end

    # retry_options never sets max_interval, so Faraday::Retry's own default
    # (Float::MAX) never triggers its "give up before sleeping" branch for a
    # realistic header value — parse_and_clamp_retry_after is the only thing
    # bounding the wait. Without it, this would sleep 99999s (over a day) per
    # attempt instead of capping at MAX_DELAY_SECONDS.
    it 'clamps a runaway Retry-After header rather than sleeping for it verbatim' do
      waited = nil
      # The block's leading `_` is the middleware instance, not a sleep
      # argument — rspec-mocks prepends the receiver to any_instance_of
      # implementation blocks by default. `.with(kind_of(Numeric))` states
      # the actual call shape (`sleep(seconds)`) explicitly, so this doesn't
      # rely on that default going unremarked.
      allow_any_instance_of(Faraday::Retry::Middleware) # rubocop:disable RSpec/AnyInstance
        .to receive(:sleep).with(kind_of(Numeric)) { |_, seconds| waited = seconds }
      calls = 0
      stubs.post('/repos/o/r/pulls/1/comments') do
        calls += 1
        body = '{"message":"You have exceeded a secondary rate limit"}'
        calls < 2 ? [403, { 'Retry-After' => '99999' }, body] : [201, {}, '{}']
      end

      build_client.post('/repos/o/r/pulls/1/comments', {})

      expect(waited).to eq(described_class::MAX_DELAY_SECONDS)
    end
  end
end
