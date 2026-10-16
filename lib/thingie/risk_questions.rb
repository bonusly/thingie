# frozen_string_literal: true

module Thingie
  # The change-risk questions put to System One about each changed file, and the ratings that
  # the `overall` answer maps to. Each rating's floor and description come from the
  # `[change_risk.ratings.<level>]` config tables.
  class RiskQuestions
    # The `overall` levels, lowest first: the order their descriptions are sent to the model.
    LEVELS = %w[trivial routine risky critical].freeze

    OVERALL_INSTRUCTIONS = "How closely should a human review this file's change before it ships? Rate only " \
                           "this file's own change, not the risk of the code it tests or describes: a test, spec, " \
                           'factory, fixture, or documentation file is Trivial unless it changes shared test setup.'

    # Each risk is a yes/no (`noul`) question with explicit true/false criteria, so the model
    # knows what to look for. The model sees only a file's diff and metadata, so every
    # criterion must be judgeable from a diff.
    RISKS = {
      security: {
        type: 'noul',
        instructions: 'Does this change introduce a security vulnerability or weaken a security control?',
        criteria: {
          'true' => 'Adds exposure or removes or weakens a protection: authentication, authorization or access ' \
                    'checks, session or token handling, input validation or output escaping, SQL, shell, eval or ' \
                    'deserialization, file paths or uploads, secrets or credentials, cryptography, or logging of ' \
                    'sensitive data.',
          'false' => 'Leaves every trust boundary as it was or strengthens one: refactors, docs, tests, and logic ' \
                     'that never touches untrusted input, access control, or sensitive data.'
        }
      },
      user_impact: {
        type: 'noul',
        instructions: 'Will end users or API clients notice this change? Judge only this file: a test, spec, ' \
                      'factory, fixture, or documentation file is never noticed by users, even when it covers ' \
                      'user-facing code.',
        criteria: {
          'true' => 'Changes what users or API clients see or get: behavior, output, UI text or layout, API ' \
                    'responses or contracts, stored data, emails or notifications, or runs a data migration.',
          'false' => 'Internal only: a refactor, tests, specs, factories, fixtures, docs, tooling, comments, ' \
                     'logging, or dev/CI configuration with no visible effect.'
        }
      },
      performance: {
        type: 'noul',
        instructions: 'Is this change likely to degrade performance or resource usage?',
        criteria: {
          'true' => 'Adds N+1 or unbounded queries, drops an index or a cache, adds unbounded loops or recursion, ' \
                    'blocking or synchronous external calls on a request path, large payloads, or much more ' \
                    'memory use.',
          'false' => 'No change to query patterns, caching, algorithmic complexity, or resource use, or makes ' \
                     'them cheaper.'
        }
      },
      new_dependencies: {
        type: 'noul',
        instructions: 'Does this change add, remove, or change the version of a third-party dependency?',
        criteria: {
          'true' => 'Adds, removes, or changes the version of a gem, package, library, base image, or external ' \
                    'service, including lockfile changes.',
          'false' => 'Uses only dependencies already present, at their current versions.'
        }
      },
      maintainability: {
        type: 'noul',
        instructions: 'Does this change make the code harder to understand, test, or maintain?',
        criteria: {
          'true' => 'Adds hard-to-follow logic, deep nesting, duplication, magic values, tight coupling, or ' \
                    'global state, or deletes tests or documentation.',
          'false' => 'Is clear, small, consistent with the surrounding code, and keeps or adds tests.'
        }
      }
    }.freeze

    # The questions to send to System One for each file.
    #
    # @return [Hash{Symbol => Hash}] the {RISKS} plus an `overall` score question with one level per rating
    attr_reader :questions

    # Validate the ratings and build the questions.
    #
    # @param ratings [Hash{String => Hash}, nil] the `change_risk.ratings` config: level => `floor` and `description`
    # @raise [Thingie::ConfigurationError] unless every level in {LEVELS}, and no other, has a non-blank
    #   description and a floor from 0 to 1, with floors rising from trivial at 0
    def initialize(ratings)
      validate(ratings)
      @floors = LEVELS.to_h { |level| [level, ratings[level]['floor']] }
      criteria = LEVELS.map { |level| "#{level.capitalize}: #{ratings[level]['description'].strip}" }
      @questions = RISKS.merge(overall: { type: 'score', instructions: OVERALL_INSTRUCTIONS, criteria: criteria })
                        .freeze
    end

    # The highest rating whose floor an overall score reaches.
    #
    # @param overall [Float] the `overall` score, 0.0-1.0
    # @return [String] one of {LEVELS}
    def rating_for(overall)
      LEVELS.reverse.find { |level| overall >= @floors[level] }
    end

    private

    def validate(ratings)
      raise ConfigurationError, 'change_risk.ratings must be a table of levels' unless ratings.is_a?(Hash)

      unknown = ratings.keys - LEVELS
      unless unknown.empty?
        raise ConfigurationError, "change_risk.ratings has unknown level(s) #{unknown.join(', ')}; " \
                                  "the levels are #{LEVELS.join(', ')}"
      end

      LEVELS.each { |level| validate_level(level, ratings[level]) }
      validate_floor_order(ratings)
    end

    def validate_level(level, rating)
      raise ConfigurationError, "change_risk.ratings.#{level} must be a table" unless rating.is_a?(Hash)

      floor = rating['floor']
      unless floor.is_a?(Numeric) && floor.between?(0, 1)
        raise ConfigurationError, "change_risk.ratings.#{level}.floor must be a number from 0 to 1, " \
                                  "got #{floor.inspect}"
      end

      description = rating['description']
      return if description.is_a?(String) && !description.strip.empty?

      raise ConfigurationError, "change_risk.ratings.#{level}.description must be a non-blank string"
    end

    def validate_floor_order(ratings)
      floors = LEVELS.map { |level| ratings[level]['floor'] }
      return if floors.first.zero? && floors.each_cons(2).all? { |lower, higher| lower < higher }

      found = LEVELS.zip(floors).map { |level, floor| "#{level} = #{floor}" }.join(', ')
      raise ConfigurationError, "change_risk.ratings floors must rise from trivial = 0 to critical, got #{found}"
    end
  end
end
