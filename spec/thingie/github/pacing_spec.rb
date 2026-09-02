# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Thingie::GitHub::Pacing do # rubocop:disable RSpec/SpecFilePathFormat
  # Records waits instead of taking them, so the specs assert the backoff
  # schedule without spending it.
  let(:host_class) do
    Class.new do
      include Thingie::GitHub::Pacing

      attr_reader :waits

      def initialize
        @waits = []
      end

      def attempt(description, &) = with_pacing_retry(description, &)

      def sleep(seconds)
        @waits << seconds
      end
    end
  end

  let(:host) { host_class.new }

  def github_error(klass, message, headers = {})
    klass.new(
      method: :post,
      url: 'https://api.github.com/repos/o/r/pulls/1/comments',
      status: 422,
      body: JSON.generate({ message: message }),
      response_headers: { 'content-type' => 'application/json' }.merge(headers)
    )
  end

  def too_quickly = github_error(Octokit::UnprocessableEntity, 'Validation Failed: was submitted too quickly')
  def secondary_limit = github_error(Octokit::Forbidden, 'You have exceeded a secondary rate limit')
  def off_diff = github_error(Octokit::UnprocessableEntity, 'pull_request_review_thread.line must be part of the diff')

  describe 'signals that mean slow down' do
    it 'retries a "submitted too quickly" 422 and returns the eventual result' do
      calls = 0
      result = host.attempt('a comment') do
        calls += 1
        raise too_quickly if calls < 3

        :posted
      end

      expect(result).to eq(:posted)
      expect(calls).to eq(3)
    end

    it 'retries a secondary rate limit' do
      calls = 0
      host.attempt('a comment') do
        calls += 1
        raise secondary_limit if calls < 2

        :posted
      end

      expect(calls).to eq(2)
    end

    it 'retries too-many-requests' do
      throttled = Octokit::TooManyRequests.new(method: :post, url: 'https://api.github.com', status: 429, body: '')
      calls = 0
      host.attempt('a comment') do
        calls += 1
        raise throttled if calls < 2

        :posted
      end

      expect(calls).to eq(2)
    end
  end

  describe 'signals that mean no' do
    it 'does not retry a 422 for a line outside the diff' do
      calls = 0

      expect do
        host.attempt('a comment') do
          calls += 1
          raise off_diff
        end
      end.to raise_error(Octokit::UnprocessableEntity)
      expect(calls).to eq(1)
      expect(host.waits).to be_empty
    end

    it 'does not retry an ordinary forbidden' do
      expect do
        host.attempt('a comment') { raise github_error(Octokit::Forbidden, 'Resource not accessible by integration') }
      end.to raise_error(Octokit::Forbidden)
      expect(host.waits).to be_empty
    end

    it 'does not swallow a non-Octokit error' do
      expect { host.attempt('a comment') { raise ArgumentError, 'bad' } }.to raise_error(ArgumentError)
    end
  end

  describe 'backoff' do
    it 'doubles the wait between attempts' do
      expect { host.attempt('a comment') { raise too_quickly } }.to raise_error(Octokit::UnprocessableEntity)

      expect(host.waits).to eq([1.0, 2.0, 4.0, 8.0])
    end

    it 'gives up after MAX_ATTEMPTS and re-raises the last error' do
      calls = 0

      expect do
        host.attempt('a comment') do
          calls += 1
          raise too_quickly
        end
      end.to raise_error(Octokit::UnprocessableEntity)
      expect(calls).to eq(described_class::MAX_ATTEMPTS)
    end

    it 'honors a Retry-After header over its own backoff' do
      error = github_error(Octokit::Forbidden, 'You have exceeded a secondary rate limit', 'retry-after' => '7')
      calls = 0
      host.attempt('a comment') do
        calls += 1
        raise error if calls < 2

        :posted
      end

      expect(host.waits).to eq([7.0])
    end

    it 'caps a very long Retry-After so a wait cannot stall the job' do
      error = github_error(Octokit::Forbidden, 'You have exceeded a secondary rate limit', 'retry-after' => '600')
      calls = 0
      host.attempt('a comment') do
        calls += 1
        raise error if calls < 2

        :posted
      end

      expect(host.waits).to eq([described_class::MAX_DELAY_SECONDS])
    end

    it 'falls back to its own backoff when the header is missing or unusable' do
      error = github_error(Octokit::Forbidden, 'You have exceeded a secondary rate limit', 'retry-after' => 'soon')
      calls = 0
      host.attempt('a comment') do
        calls += 1
        raise error if calls < 2

        :posted
      end

      expect(host.waits).to eq([1.0])
    end
  end
end
