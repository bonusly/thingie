# frozen_string_literal: true

require_relative 'bench'

module Bench
  # The System One eval: the bench cases scored with the change-risk questions alone, once per decision model,
  # against the answers expected per file and question in cases/<name>/risk.yml. See evals/bench/README.md.
  module Risk
    LEVELS = Thingie::RiskQuestions::LEVELS
    PROBABILITIES = Thingie::RiskQuestions::RISKS.keys.map(&:to_s).freeze
    QUESTIONS = (PROBABILITIES + ['overall']).freeze
    REFS = %w[final-push first-push].freeze

    # Expected answers per push and scored file: true/false for each probability question (is the file
    # load-bearing for it), one of {LEVELS} for `overall`. Every key is optional; what is absent is unscored.
    module Expectations
      HEADER = <<~YAML
        # Expected System One answers per scored file, by push: true/false for each probability question, a
        # rating for overall. Bootstrapped from a run with `evals/bench/risk --write-expectations <run file>`,
        # then corrected by hand; the bootstrap never overwrites an entry that is already here.
      YAML

      module_function

      def path(kase) = File.join(kase.dir, 'risk.yml')

      # @param kase [Bench::Case]
      # @return [Hash{String => Hash{String => Hash}}] ref => path => question => expected answer; {} without a file
      # @raise [ArgumentError] on an unknown push or question, or an answer of the wrong kind
      def load(kase)
        file = path(kase)
        return {} unless File.exist?(file)

        data = YAML.safe_load_file(file)
        return {} if data.nil?

        check(kase, data)
        data
      end

      # @param kase [Bench::Case]
      # @param data [Hash] as {load} returns it
      def write(kase, data)
        pushes = REFS.filter_map { |ref| [ref, data[ref].sort.to_h] unless data[ref].to_h.empty? }.to_h
        File.write(path(kase), HEADER + YAML.dump(pushes).delete_prefix("---\n"))
      end

      # Adds an expectation for every (ref, path) in the entries that has none; never changes an existing one.
      #
      # @param kase [Bench::Case]
      # @param entries [Array<Hash>] run-file entries for this case, repeat 0, one model, no 'error'
      # @return [Integer] how many file entries were added
      def bootstrap(kase, entries)
        data = load(kase)
        added = 0
        entries.each do |entry|
          known = data[entry['ref']] ||= {}
          entry['files'].each do |file, risk|
            next if known.key?(file)

            known[file] = guess(risk)
            added += 1
          end
        end
        write(kase, data) if added.positive?
        added
      end

      # A starting guess from one run's answers: yes at 0.5 and over, and the rating it got.
      def guess(risk)
        scores = risk['scores']
        PROBABILITIES.filter_map { |q| [q, scores[q] >= 0.5] if scores[q] }.to_h.merge('overall' => risk['rating'])
      end

      def check(kase, data)
        raise ArgumentError, "#{kase.name}: risk.yml must map pushes to files" unless data.is_a?(Hash)

        data.each do |ref, files|
          raise ArgumentError, "#{kase.name}: risk.yml push #{ref.inspect} is not #{REFS.join(' or ')}" unless
            REFS.include?(ref)
          raise ArgumentError, "#{kase.name}: risk.yml has first-push but the case has no first-push/" if
            ref == 'first-push' && !kase.first_push?
          raise ArgumentError, "#{kase.name}: risk.yml #{ref} must map paths to answers" unless files.is_a?(Hash)

          files.each { |file, answers| check_answers(kase, "#{ref} #{file}", answers) }
        end
      end

      def check_answers(kase, where, answers)
        raise ArgumentError, "#{kase.name}: risk.yml #{where} must map questions to answers" unless
          answers.is_a?(Hash)

        answers.each do |question, value|
          raise ArgumentError, "#{kase.name}: risk.yml #{where} has unknown question #{question.inspect}" unless
            QUESTIONS.include?(question)

          allowed = question == 'overall' ? LEVELS : [true, false]
          next if allowed.include?(value)

          raise ArgumentError, "#{kase.name}: risk.yml #{where} #{question} is #{value.inspect}, " \
                               "not #{allowed.join(' or ')}"
        end
      end
    end

    # One (case, push, model) scored the way `thingie review` scores a changeset with System One on.
    module Scoring
      module_function

      # @param kase [Bench::Case]
      # @param repo [String] the case's built repo
      # @param ref [String] final-push or first-push
      # @param overrides [Hash] the run's config, as from {Bench.overrides}
      # @param model [String] the System One decision model
      # @param expectations [Hash] the case's {Expectations.load}
      # @param classifier [Thingie::SystemOneClassifier, nil] built from the config when nil
      # @return [Hash] one run-file entry; 'repeat' is left for the caller
      def score(kase:, repo:, ref:, overrides:, model:, expectations:, classifier: nil)
        started = clock
        entry = { 'case' => kase.name, 'ref' => ref, 'model' => model, 'repeat' => nil }
        config = Thingie::Configuration.new(
          root: repo, overrides: overrides.merge('system_one_enabled' => true, 'system_one_model' => model)
        )
        changeset = Thingie::Changeset.new(repo_path: repo, head_ref: "pr-#{ref}", base_ref: 'pr-base',
                                           exclude_files: config['exclude_files'], merge_base: false)
        risk_questions = Thingie::RiskQuestions.new(config.dig('change_risk', 'ratings'))
        classifier ||= Thingie::SystemOneClassifier.new(config)
        result = Thingie::ChangeRiskScorer.new(changeset: changeset, classifier: classifier,
                                               risk_questions: risk_questions,
                                               concurrency: config['max_concurrent_tasks']).call
        entry.merge('seconds' => (clock - started).round(1), 'rating' => result.rating,
                    'max' => result.max.transform_keys(&:to_s),
                    'files' => files(result, expectations.fetch(ref, {})), 'error' => nil)
      rescue Thingie::SystemOneError, Thingie::ConfigurationError => e
        warn "[risk] #{kase.name} #{ref} #{model}: #{e.class}: #{e.message}"
        entry.merge('seconds' => (clock - started).round(1), 'rating' => nil, 'max' => {}, 'files' => {},
                    'error' => "#{e.class}: #{e.message}")
      end

      def files(result, expected)
        result.files.to_h do |path, risk|
          [path, { 'scores' => risk.scores.transform_keys(&:to_s), 'rating' => risk.rating,
                   'expected' => expected[path] }]
        end
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Per decision model, every scored file of every entry (both pushes, every repeat) against its expectations.
    module Summary
      module_function

      # @param entries [Array<Hash>] run-file entries (with 'repeat')
      # @return [Hash{String => Hash}] model => summary
      def compute(entries)
        entries.group_by { |entry| entry['model'] }.transform_values { |mine| for_model(mine) }
      end

      # Hits, means, AUC and Brier count each (case, ref, path) once, at its first answer; spread uses every repeat.
      def for_model(entries)
        every = entries.flat_map do |entry|
          entry['files'].map { |path, risk| risk.merge('key' => [entry['case'], entry['ref'], path]) }
        end
        files = every.uniq { |file| file['key'] }
        repeats = entries.map { |entry| entry['repeat'] }.uniq.size
        questions = PROBABILITIES.to_h { |q| [q, probability(files, q, spread(every, q, repeats))] }
                                 .merge('overall' => overall(files, spread(every, 'overall', repeats)))
        { 'entries' => entries.size, 'errors' => entries.count { |entry| entry['error'] }, 'files' => files.size,
          'expected' => files.count { |file| file['expected'] }, 'questions' => questions,
          'brier' => mean(PROBABILITIES.filter_map { |q| questions.dig(q, 'brier') }, digits: 3),
          'seconds' => (entries.sum { |entry| entry['seconds'].to_f } / repeats).round(1) }
      end

      def probability(files, question, spread)
        scored = files.filter_map { |f| [f['scores'][question], f.dig('expected', question)] if f['scores'][question] }
        return nil if scored.empty?

        judged = scored.reject { |pair| pair.last.nil? }
        yes = judged.filter_map { |score, want| score if want }
        no = judged.filter_map { |score, want| score unless want }
        { 'mean' => mean(scored.map(&:first)), 'yes_mean' => mean(yes), 'no_mean' => mean(no), 'auc' => auc(yes, no),
          'brier' => mean(judged.map { |score, want| (score - (want ? 1 : 0))**2 }, digits: 3),
          'hits' => { 'found' => judged.count { |score, want| (score >= 0.5) == want }, 'total' => judged.size },
          'spread' => spread }
      end

      def overall(files, spread)
        scored = files.select { |f| f['scores']['overall'] }
        return nil if scored.empty?

        judged = scored.select { |f| f.dig('expected', 'overall') }
        { 'mean' => mean(scored.map { |f| f['scores']['overall'] }),
          'hits' => { 'found' => judged.count { |f| f['rating'] == f['expected']['overall'] }, 'total' => judged.size },
          'by_expected' => by_expected(judged), 'confusion' => confusion(judged),
          'spread' => spread }
      end

      def by_expected(judged)
        LEVELS.to_h do |level|
          scores = judged.select { |f| f['expected']['overall'] == level }.map { |f| f['scores']['overall'] }
          [level, { 'mean' => mean(scores), 'n' => scores.size }]
        end
      end

      def confusion(judged)
        LEVELS.to_h do |want|
          wanted = judged.select { |f| f['expected']['overall'] == want }
          [want, LEVELS.to_h { |got| [got, wanted.count { |f| f['rating'] == got }] }]
        end
      end

      # Mann-Whitney: the chance an expected-yes file outscores an expected-no one, ties counting half.
      def auc(positives, negatives)
        return nil if positives.empty? || negatives.empty?

        wins = positives.product(negatives).sum { |pos, neg| (pos <=> neg).succ / 2.0 }
        (wins / (positives.size * negatives.size)).round(2)
      end

      # Mean over files of the score's range across repeats; nil with one repeat.
      def spread(files, question, repeats)
        return nil if repeats < 2

        ranges = files.group_by { |f| f['key'] }.values.filter_map do |same|
          scores = same.filter_map { |f| f['scores'][question] }
          scores.max - scores.min unless scores.empty?
        end
        mean(ranges)
      end

      def mean(values, digits: 2)
        values.empty? ? nil : (values.sum.to_f / values.size).round(digits)
      end
    end

    # The run file: provenance, the summary, and every entry.
    module RunFile
      module_function

      def assemble(entries, label:, models:, variant:, floors:)
        { 'label' => label, 'at' => Time.now.utc.iso8601, 'sha' => Bench.sha, 'thingie' => Thingie::VERSION,
          'variant' => variant, 'models' => models, 'floors' => floors,
          'summary' => Summary.compute(entries), 'entries' => entries }
      end
    end

    # The Markdown report of a run file: a headline row per model, its per-question tables, every entry, and
    # every file's answers.
    module Report
      REVIEW_NEED = Thingie::ChangeRiskSection::OVERALL_LABEL

      module_function

      # @param run [Hash] a run file
      # @return [String] Markdown
      def render(run)
        parts = ['## Risk eval results', provenance(run), headline(run['summary'])]
        run['summary'].each { |model, summary| parts << model_section(model, summary, run['floors']) }
        parts << cases(run['entries'])
        parts << files(run['entries'])
        parts.join("\n\n")
      end

      def provenance(run)
        "`#{run['label']}` on #{run['models'].join(', ')} (variant #{run['variant']}), Thingie #{run['thingie']}"
      end

      def headline(summary)
        lines = head(['Model', 'Files', 'With expectations', 'Errors', 'Rating hits', 'Brier', 'Seconds'])
        summary.each do |model, s|
          lines << row([model, s['files'], s['expected'], s['errors'],
                        Bench::Report.fraction(s.dig('questions', 'overall', 'hits')), s['brier'], s['seconds']])
        end
        lines.join("\n")
      end

      def model_section(model, summary, floors)
        questions = summary['questions']
        parts = ["### #{model}", questions_table(questions)]
        overall = questions['overall']
        parts += [review_need(overall, floors), confusion(overall)] if overall
        parts.join("\n\n")
      end

      def questions_table(questions)
        spread = QUESTIONS.any? { |q| questions.dig(q, 'spread') }
        names = ['Question', 'Mean', 'Expected yes', 'Expected no', 'AUC', 'Brier', 'Hits']
        lines = head(spread ? names + ['Spread'] : names)
        PROBABILITIES.each do |q|
          s = questions[q] || {}
          cells = [q, s['mean'], s['yes_mean'], s['no_mean'], s['auc'], s['brier'], Bench::Report.fraction(s['hits'])]
          lines << row(spread ? cells + [s['spread']] : cells)
        end
        lines.join("\n")
      end

      def review_need(overall, floors)
        means = LEVELS.map do |level|
          group = overall['by_expected'][level]
          "#{level} #{Bench::Report.cell(group['mean'])} (#{group['n']})"
        end
        bars = LEVELS.map { |level| "#{level} #{floors[level].to_s.delete_suffix('.0')}" }
        spread = " Spread: #{overall['spread']}." if overall['spread']
        "#{REVIEW_NEED.capitalize} by expected rating (mean score, n): #{means.join(' · ')}. " \
          "Floors: #{bars.join(' · ')}.#{spread}"
      end

      def confusion(overall)
        lines = head(['Expected \\ Got', *LEVELS])
        LEVELS.each { |want| lines << row([want, *LEVELS.map { |got| overall['confusion'][want][got] }]) }
        lines.join("\n")
      end

      # A Repeat column only when the run was repeated.
      def cases(entries)
        repeated = entries.map { |e| e['repeat'] }.uniq.size > 1
        lines = head(['Case', 'Ref', 'Model', *('Repeat' if repeated), 'Rating', REVIEW_NEED.capitalize, 'Files',
                      'Rating hits', 'Seconds'])
        entries.each do |e|
          judged = e['files'].values.select { |f| f.dig('expected', 'overall') }
          hits = { 'found' => judged.count { |f| f['rating'] == f['expected']['overall'] }, 'total' => judged.size }
          lines << row([e['case'], e['ref'], e['model'], *(e['repeat'] if repeated), rating(e),
                        score(e.dig('max', 'overall')), e['files'].size, Bench::Report.fraction(hits), e['seconds']])
        end
        "### Cases\n\n#{lines.join("\n")}"
      end

      def rating(entry)
        entry['error'] ? "Error: #{entry['error']}" : entry['rating']
      end

      def files(entries)
        tables = entries.select { |e| e['repeat'].to_i.zero? && !e['error'] && e['files'].any? }.map do |e|
          "#### #{e['case']} #{e['ref']} — #{e['model']}\n\n#{files_table(e['files'])}"
        end
        "<details><summary>Files</summary>\n\n#{tables.join("\n\n")}\n\n</details>"
      end

      def files_table(files)
        lines = head(['File', 'Rating', 'Expected', *PROBABILITIES, REVIEW_NEED])
        sorted = files.sort_by { |path, risk| [-(risk['scores']['overall'] || -1), path] }
        sorted.each do |path, risk|
          expected = risk['expected'] || {}
          answers = PROBABILITIES.map { |q| answer(risk['scores'][q], expected[q]) }
          lines << row([path, risk['rating'], expected['overall'], *answers, score(risk['scores']['overall'])])
        end
        lines.join("\n")
      end

      # "0.12 yes" with an expectation, "0.12" without.
      def answer(value, expected)
        return nil if value.nil?

        [score(value), { true => 'yes', false => 'no' }[expected]].compact.join(' ')
      end

      def score(value) = value && format('%.2f', value)

      def head(names)
        [Bench::Report.row(names), Bench::Report.row(names.map { '---' })]
      end

      # Pipes and newlines in a value would break the table.
      def row(cells)
        Bench::Report.row(cells.map { |c| Bench::Report.cell(c).gsub('|', '\|').tr("\n", ' ') })
      end
    end
  end
end
