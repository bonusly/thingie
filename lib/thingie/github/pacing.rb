# frozen_string_literal: true

require 'octokit'
require 'faraday/retry'

module Thingie
  module GitHub
    # Builds the Faraday middleware every Octokit::Client GitHub write goes
    # through, so a burst of PR comments retries when GitHub is only asking for
    # a slower pace and never retries when a failure means something else.
    #
    # A review with many findings posts many comments in a row, and GitHub
    # answers a burst with `422 "was submitted too quickly"` on the
    # review-comment endpoint, or `403 "exceeded a secondary rate limit"` once
    # the burst is bad enough. Treating either as a permanent failure and
    # moving straight to the next comment turns a throttle signal into a
    # machine gun: on special_sauce#26652 the burst escalated to the secondary
    # limit and the run ended with no review posted at all, and no decision
    # recorded anywhere.
    #
    # Octokit already installs `Faraday::Retry::Middleware` by default, ahead
    # of its own `Octokit::Response::RaiseError` in the stack — so by the time
    # retry logic runs, a failing response has already become a raised
    # `Octokit::Error` subclass, not a plain response with a status code.
    # `{.middleware}` replaces Octokit's bare default (two retries, 5xx and
    # timeouts only) with one configured for the throttle signals this gem
    # actually hits, and for making the "still failing after every attempt"
    # case a type nothing else can mistake for a different failure.
    module Pacing
      # Raised once every attempt has been refused. Deliberately not an
      # `Octokit::Error`: GitHub reports "was submitted too quickly" as a 422,
      # the same class it uses for a PR comment on a line outside the diff, and
      # `Commenter#post_issue_inline?` rescues that class to route off-diff
      # findings into the summary comment. If exhaustion re-raised the
      # original `Octokit::UnprocessableEntity`, that rescue would catch it and
      # file a comment GitHub refused as one that merely had nowhere to go.
      class Throttled < StandardError
        # The last error GitHub returned, kept so callers can inspect the
        # status and headers behind the refusal.
        #
        # @return [Exception] the last error GitHub returned
        attr_reader :cause_error

        # Builds the error raised once every attempt has been refused.
        #
        # @param description [String] what was being attempted, e.g. `"POST
        #   /repos/o/r/pulls/1/comments"`
        # @param cause_error [Exception] the last error GitHub returned
        def initialize(description, cause_error)
          @cause_error = cause_error
          super("GitHub refused #{description} after #{MAX_ATTEMPTS} attempts: #{cause_error.message}")
        end
      end

      # Attempts per request, including the first.
      MAX_ATTEMPTS = 5
      # First backoff, doubled each retry: 1s, 2s, 4s, 8s for a 5-attempt run.
      BASE_DELAY_SECONDS = 1.0
      # Ceiling on any single wait, including one read from a Retry-After
      # header, so a long stated wait cannot stall a CI job.
      MAX_DELAY_SECONDS = 30.0

      # GitHub's response when comments arrive faster than it wants them. The
      # same 422 class covers a comment on a line outside the diff, which is a
      # permanent "no" and must not be retried — this is what tells them apart.
      SUBMITTED_TOO_QUICKLY = /submitted too quickly/i

      # Octokit::Error.error_for_403 maps two different messages into the same
      # Octokit::TooManyRequests class: the secondary/abuse rate limit (a short
      # burst-detection cooldown, recovers in seconds) and the *primary* API
      # rate limit (a fixed hourly budget that only resets at a specific time,
      # often up to an hour away). Only the former is worth retrying here —
      # five ~30s-capped attempts cannot outlast an hour-away reset, so
      # retrying the primary limit just wastes time and then hides the real
      # "rate limit exceeded" diagnostic behind a generic Throttled refusal.
      SECONDARY_RATE_LIMIT = /secondary rate limit/i

      class << self
        # The Faraday middleware stack for an `Octokit::Client`. Mirrors
        # `Octokit::Default::MIDDLEWARE` exactly, replacing only the retry step.
        #
        # @param adapter [Object, Array] the Faraday adapter to terminate the
        #   stack with — a single value (e.g. `Faraday.default_adapter`) or an
        #   `[adapter, *args]` array (e.g. `[:test, stubs]`); overridable so
        #   specs can drive the real middleware chain through
        #   `Faraday::Adapter::Test` instead of a real connection
        # @return [Faraday::RackBuilder] pass as `Octokit::Client.new(middleware:)`
        def middleware(adapter: Faraday.default_adapter)
          Faraday::RackBuilder.new do |builder|
            builder.use Faraday::Retry::Middleware, retry_options
            builder.use Octokit::Middleware::FollowRedirects
            builder.use Octokit::Response::RaiseError
            builder.use Octokit::Response::FeedParser
            builder.adapter(*Array(adapter))
          end
        end

        # Options for `Faraday::Retry::Middleware`. Public so specs can drive
        # `retry_if` and `exhausted_retries_block` directly without standing up
        # a real Faraday connection.
        #
        # @return [Hash] middleware options
        def retry_options
          {
            max: MAX_ATTEMPTS - 1,
            interval: BASE_DELAY_SECONDS,
            backoff_factor: 2,
            # methods: [] forces every request through retry_if, GET included —
            # no HTTP method gets an unconditional retry on any listed exception.
            methods: [],
            # Octokit::ClientError is the broad 4xx catch-all Error.from_response
            # raises for any status it has no dedicated branch for — including a
            # genuine 429, which Octokit 10 does not classify into
            # Octokit::TooManyRequests. Listing it here only makes it eligible for
            # retry_if to inspect; pacing_error? still checks response_status
            # before treating one as a pacing signal.
            exceptions: [Octokit::UnprocessableEntity, Octokit::TooManyRequests, Octokit::AbuseDetected,
                         Octokit::ClientError],
            retry_if: method(:pacing_error?),
            retry_block: method(:log_retry),
            exhausted_retries_block: method(:raise_throttled),
            # `max_interval` is deliberately left unset (defaults to
            # Float::MAX) — its own cap works by skipping the retry outright
            # once a header exceeds it, which falls through to re-raising the
            # *original* Octokit error instead of reaching
            # exhausted_retries_block: exactly the untyped escape this module
            # exists to prevent. parse_and_clamp_retry_after bounds the parsed
            # value itself instead, so a long stated wait is capped rather
            # than skipped, and every exhaustion still reaches
            # {.raise_throttled}.
            header_parser_block: method(:parse_and_clamp_retry_after)
          }
        end

        # Whether an error means "slow down", not "no" — the actual retry
        # decision (`methods: []` above routes every request through this,
        # regardless of HTTP verb).
        #
        # `Octokit::TooManyRequests` covers two different 403 bodies —
        # Octokit's own `Error.error_for_403` classifies both "rate limit
        # exceeded" (the primary hourly budget) and "exceeded a secondary
        # rate limit" (a short burst cooldown) into this one class. Only the
        # secondary wording is retried; see {SECONDARY_RATE_LIMIT}. It does
        # *not* cover a genuine HTTP 429: `Error.from_response` has no
        # dedicated branch for status 429, so that falls through to the
        # generic `Octokit::ClientError` — checked by status here, since the
        # class alone covers plenty of 4xx statuses that are not pacing
        # signals. `Octokit::UnprocessableEntity` is shared by a genuine
        # pacing 422 and an ordinary one (a comment outside the diff), so
        # only the pacing wording is retried there too.
        #
        # @param _env [Faraday::Env] the request environment (unused; the
        #   decision only needs the exception)
        # @param exception [Exception] the error Octokit raised for this attempt
        # @return [Boolean] whether this error means "slow down"
        def pacing_error?(_env, exception)
          case exception
          when Octokit::UnprocessableEntity then exception.message.match?(SUBMITTED_TOO_QUICKLY)
          when Octokit::TooManyRequests then exception.message.match?(SECONDARY_RATE_LIMIT)
          when Octokit::AbuseDetected then true
          when Octokit::ClientError then exception.response_status == 429
          else false
          end
        end

        # Logs each retry as one line, called only when an attempt is actually
        # about to be retried (never for a permanent failure).
        #
        # @param env [Faraday::Env] the request environment
        # @param retry_count [Integer] retries already made, 0-based
        # @param will_retry_in [Float] seconds until the next attempt
        # @return [void]
        def log_retry(env:, retry_count:, will_retry_in:, **)
          # faraday-retry's own retry_count is 0-based and counts retries, not
          # attempts — retry_count: 0 fires after attempt 1 fails, right before
          # attempt 2. Labeling that "attempt 1 of MAX_ATTEMPTS" describes what
          # just failed, not what's about to happen. Count retries instead
          # (1-based, out of MAX_ATTEMPTS - 1 possible) to avoid the mismatch.
          warn "GitHub asked for a slower pace on #{request_description(env)}; " \
               "waiting #{will_retry_in.round(1)}s (retry #{retry_count + 1} of #{MAX_ATTEMPTS - 1})."
        end

        # Raises {Throttled} once every attempt has been refused. A plain
        # method call inside `Faraday::Retry`'s rescue clause, so raising here
        # propagates immediately and pre-empts the original exception it would
        # otherwise re-raise.
        #
        # @param env [Faraday::Env] the request environment
        # @param exception [Exception] the last error GitHub returned
        # @return [void]
        def raise_throttled(env:, exception:, **)
          raise Throttled.new(request_description(env), exception)
        end

        # Renders a request as `"METHOD /path"` for a log line or error message.
        #
        # @param env [Faraday::Env] the request environment
        # @return [String] a short description of the request, for logging
        def request_description(env)
          "#{env.method.to_s.upcase} #{env.url&.path}"
        end

        # Parses a Retry-After or RateLimit-Reset header value the same way
        # `Faraday::Retry::Middleware`'s own default does (an RFC 2822 date, or
        # a bare number of seconds), then clamps it to {MAX_DELAY_SECONDS}.
        #
        # @param value [String, nil] the raw header value
        # @return [Float, nil] seconds to wait, or nil if unparseable/non-positive
        def parse_and_clamp_retry_after(value)
          seconds = begin
            DateTime.rfc2822(value).to_time - Time.now.utc
          rescue ArgumentError, TypeError
            value.to_f
          end
          return nil unless seconds.positive?

          [seconds, MAX_DELAY_SECONDS].min
        end
      end
    end
  end
end
