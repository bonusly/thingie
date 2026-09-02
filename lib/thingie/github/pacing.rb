# frozen_string_literal: true

require 'octokit'

module Thingie
  module GitHub
    # Retries GitHub writes that failed for pacing reasons rather than for
    # anything wrong with the request.
    #
    # A review with many findings posts many comments in a row, and GitHub
    # answers a burst with `422 "was submitted too quickly"` on the
    # review-comment endpoint. Treating that as a permanent failure and moving
    # straight to the next comment turns a throttle signal into a machine gun:
    # on special_sauce#26652 the burst escalated to a secondary rate limit and
    # the run ended with no review posted at all.
    #
    # Retries only signals that mean "slow down". A 422 for an unpostable line
    # (the common off-diff case) is not retried and still reaches its caller.
    module Pacing
      # Raised when GitHub is still refusing after every attempt.
      #
      # Deliberately not an Octokit error. GitHub reports "was submitted too
      # quickly" as a 422, the same class it uses for a line outside the diff,
      # and `Commenter#post_issue_inline?` rescues that class to route off-diff
      # findings to the summary. Re-raising the original there would file a
      # comment GitHub refused as one that merely had nowhere to go, reporting
      # a clean post that never happened.
      class Throttled < StandardError
        # The last error GitHub returned, kept so callers can inspect the
        # status and headers behind the refusal.
        #
        # @return [Octokit::Error] the last error GitHub returned
        attr_reader :cause_error

        # Builds the error raised once every attempt has been refused.
        #
        # @param description [String] what was being posted
        # @param cause_error [Octokit::Error] the last error GitHub returned
        def initialize(description, cause_error)
          @cause_error = cause_error
          super("GitHub refused #{description} after #{MAX_ATTEMPTS} attempts: #{cause_error.message}")
        end
      end

      # Attempts per call, including the first.
      MAX_ATTEMPTS = 5
      # First backoff, doubled each retry.
      BASE_DELAY_SECONDS = 1.0
      # Ceiling per wait, so a long Retry-After cannot stall a CI job.
      MAX_DELAY_SECONDS = 30.0

      # GitHub's response when comments arrive faster than it wants them.
      SUBMITTED_TOO_QUICKLY = /submitted too quickly/i
      # Both the abuse-detection and secondary-rate-limit wordings.
      SLOW_DOWN = /secondary rate limit|abuse detection/i

      private

      # Runs the block, retrying while GitHub asks for a slower pace.
      #
      # @param description [String] what is being attempted, for the log line
      # @yield the GitHub call to make
      # @return [Object] the block's value
      def with_pacing_retry(description)
        attempt = 1
        begin
          yield
        rescue Octokit::Error => e
          raise unless pacing_error?(e)
          raise Throttled.new(description, e) if attempt >= MAX_ATTEMPTS

          delay = pacing_delay(e, attempt)
          warn "GitHub asked for a slower pace on #{description}; waiting #{delay}s " \
               "(attempt #{attempt} of #{MAX_ATTEMPTS})."
          sleep(delay)
          attempt += 1
          retry
        end
      end

      # @param error [Octokit::Error] the raised error
      # @return [Boolean] whether the error means "slow down" rather than "no"
      def pacing_error?(error)
        case error
        when Octokit::TooManyRequests then true
        when Octokit::UnprocessableEntity then error.message.match?(SUBMITTED_TOO_QUICKLY)
        when Octokit::Forbidden then error.message.match?(SLOW_DOWN)
        else false
        end
      end

      # Honors GitHub's own Retry-After when it sends one, since it knows how
      # long the block lasts; otherwise backs off exponentially.
      #
      # @param error [Octokit::Error] the raised error
      # @param attempt [Integer] the attempt that just failed, 1-based
      # @return [Float] seconds to wait
      def pacing_delay(error, attempt)
        [retry_after(error) || (BASE_DELAY_SECONDS * (2**(attempt - 1))), MAX_DELAY_SECONDS].min
      end

      # Never raises: this runs while handling another error, and a failure
      # here would mask the error we are retrying. An Octokit error built
      # without a response raises on `response_headers`.
      #
      # @param error [Octokit::Error] the raised error
      # @return [Float, nil] the Retry-After header in seconds, when present
      def retry_after(error)
        value = error.response_headers.to_h['retry-after'].to_f
        value.positive? ? value : nil
      rescue StandardError
        nil
      end
    end
  end
end
