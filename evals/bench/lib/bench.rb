# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require 'tomlrb'
require 'yaml'

# Benchmark: seeded pull requests against a fixture todo app, run through the review pipeline (review, critic,
# post-process; nothing posted) and scored on five dimensions against labels written in advance.
# See evals/bench/README.md.
module Bench
  ROOT = File.expand_path('..', __dir__)
  APP = File.join(ROOT, 'app')
  CONFIG = File.join(ROOT, 'config.toml')
  NAME = /\A[\w-]+\z/

  module_function

  # The config a run uses: config.toml with the variant's sections deep-merged over it, so a variant names
  # only what it changes. Also the Scorer's config, so a rescore matches with the same model as the run.
  #
  # @param variant [String] a name under variants/
  # @return [Hash] a full config hash, as overrides for Thingie::Configuration
  def overrides(variant, pinned: CONFIG, variants: File.join(ROOT, 'variants'))
    base = Tomlrb.load_file(pinned)
    layer = Tomlrb.load_file(File.join(variants, "#{variant}.toml"))
    deep_merge(base, layer)
  end

  def deep_merge(base, override)
    return override unless base.is_a?(Hash) && override.is_a?(Hash)

    base.merge(override) { |_key, old, new| deep_merge(old, new) }
  end

  # The gem checkout's short sha, for run labels; 'nogit' outside a checkout.
  def sha
    out = IO.popen(['git', '-C', File.expand_path('..', ROOT), 'rev-parse', '--short', 'HEAD'], err: File::NULL, &:read)
    out.to_s.strip.then { |s| s.empty? ? 'nogit' : s }
  rescue SystemCallError
    'nogit'
  end

  # One seeded PR: the fixture app plus an overlay of files at head (and, optionally, at an earlier push),
  # its title and body, and the labels every finding is scored against.
  class Case
    PUSHES = %w[first both final].freeze
    LABELS = %w[real nit wrong].freeze

    attr_reader :name, :dir, :data

    def self.all
      cases = File.join(ROOT, 'cases')
      return [] unless File.directory?(cases)

      names = Dir.children(cases).sort
      names.select { |name| File.directory?(File.join(cases, name)) }.map { |name| load(name) }
    end

    def self.load(name)
      raise ArgumentError, "case name #{name.inspect} must be letters, digits, - or _" unless name.match?(NAME)

      dir = File.join(ROOT, 'cases', name)
      new(name, dir, YAML.safe_load_file(File.join(dir, 'case.yml')))
    end

    def initialize(name, dir, data)
      @name = name
      @dir = dir
      @data = data
      check_labels
    end

    def title = data.fetch('title')
    def body = data.fetch('body', '')
    def labels = data.fetch('labels')
    def first_push? = File.directory?(File.join(dir, 'first-push'))

    # The labels a review of `ref` is scored against: at the final push, the defects still there (`both` and
    # `final`); at the first push, the ones there then (`first` and `both`). A label with no `push` is `both`.
    def labels_at(ref)
      present = ref == 'first-push' ? %w[first both] : %w[both final]
      labels.select { |label| present.include?(label.fetch('push', 'both').to_s) }
    end

    # A fresh git repo: the fixture app tagged `pr-base`, then the overlays as `pr-first-push` (when present)
    # and `pr-final-push`. Prefixed because a tag named `head` collides with HEAD on a case-insensitive
    # filesystem.
    #
    # @return [String] the repo path
    def build(config_path = CONFIG)
      repo = File.join(ROOT, 'tmp', name)
      FileUtils.rm_rf(repo)
      FileUtils.mkdir_p(File.dirname(repo))
      FileUtils.cp_r(APP, repo)
      install_config(repo, config_path)
      git(repo, 'init', '-q', '-b', 'main')
      commit(repo, 'pr-base')
      if first_push?
        overlay(repo, 'first-push', data.fetch('first_push_delete', []))
        commit(repo, 'pr-first-push')
      end
      overlay(repo, 'final-push', data.fetch('delete', []))
      commit(repo, 'pr-final-push')
      repo
    end

    private

    def check_labels
      labels.each do |label|
        raise ArgumentError, "#{name}: label #{label['title'].inspect} has no file" unless label['file']
        unless LABELS.include?(label['label'])
          raise ArgumentError, "#{name}: #{label['title']} is #{label['label'].inspect}, not real, nit or wrong"
        end

        push = label.fetch('push', 'both').to_s
        raise ArgumentError, "#{name}: #{label['title']} has push #{push.inspect}" unless PUSHES.include?(push)
        raise ArgumentError, "#{name}: #{label['title']} is at the first push but the case has no first-push/" if
          push == 'first' && !first_push?
      end
    end

    def install_config(repo, config_path)
      FileUtils.mkdir_p(File.join(repo, '.thingie'))
      FileUtils.cp(config_path, File.join(repo, '.thingie', 'config.toml'))
      models = File.expand_path('../../.thingie/models.json', ROOT)
      FileUtils.cp(models, File.join(repo, '.thingie', 'models.json')) if File.exist?(models)
    end

    def overlay(repo, layer, deletes)
      source = File.join(dir, layer)
      Dir.glob('**/*', File::FNM_DOTMATCH, base: source).each do |path|
        from = File.join(source, path)
        next if File.directory?(from)

        to = File.join(repo, path)
        FileUtils.mkdir_p(File.dirname(to))
        FileUtils.cp(from, to)
      end
      deletes.each do |path|
        raise ArgumentError, "#{name}: delete path #{path.inspect} must stay inside the repo" if
          path.start_with?('/') || path.split('/').include?('..')

        FileUtils.rm_rf(File.join(repo, path))
      end
    end

    def commit(repo, tag)
      git(repo, 'add', '-A')
      git(repo, '-c', 'user.name=bench', '-c', 'user.email=bench@example.com', 'commit', '-q', '-m', tag,
          '--allow-empty')
      git(repo, 'tag', tag)
    end

    def git(repo, *)
      system('git', '-C', repo, *, exception: true)
    end
  end

  # The pipeline pieces, built the way `thingie review` builds them, over one built repo and one ref.
  class Pipeline
    attr_reader :config, :usage, :changeset

    def initialize(repo:, ref:, overrides:, pull_request:)
      @repo = repo
      @config = Thingie::Configuration.new(root: repo, overrides: overrides)
      @changeset = Thingie::Changeset.new(repo_path: repo, head_ref: "pr-#{ref}", base_ref: 'pr-base',
                                          exclude_files: @config['exclude_files'], merge_base: false)
      @pull_request = pull_request
      @usage = Thingie::Stats::Usage.new
    end

    # First pass only: findings after the severity cap, before the critic.
    def review
      with_env('VERIFY_ENABLED' => 'false') do
        reviewer = Thingie::Reviewer.new(**reviewer_args)
        report = reviewer.review
        @usage = reviewer.usage
        { 'findings' => (report.issues + report.held_back_issues).map(&:to_h),
          'warnings' => report.processing_warnings, 'files' => report.number_of_processed_files }
      end
    end

    # The second look, the confidence line and the repeat check, on first-pass findings: what would be posted
    # as threads, and what would be folded into the summary.
    def critic(findings)
      issues = findings.map { |hash| Thingie::Issue.from_hash(hash) }
      verifier = Thingie::Verifier.new(config: @config, changeset: @changeset, prompt_builder: prompt_builder,
                                       llm_client: Thingie::LlmClient.new(@config), tools: tools, usage: @usage)
      kept = verifier.call(issues)
      posted, held_back = Thingie::PostProcessor.new(@config['post_process']).split_confidence(kept)
      posted = dedupe(posted)
      { 'posted' => posted.map(&:to_h), 'held_back' => held_back.map(&:to_h), 'rejected' => issues.size - kept.size,
        'warnings' => verifier.warnings }
    end

    def changed_lines
      @changeset.files.sum { |file| @changeset.changed_lines_for(file)&.size.to_i }
    end

    private

    # The Reviewer in this tree takes `pull_request:` from 0.8.8 (#135); until that lands, the case's title
    # and body are not shown to the model.
    def reviewer_args
      args = { config: @config, changeset: @changeset, prompt_builder: prompt_builder,
               llm_client: Thingie::LlmClient.new(@config), tools: tools }
      accepts = Thingie::Reviewer.instance_method(:initialize).parameters.include?(%i[key pull_request])
      accepts ? args.merge(pull_request: @pull_request) : args
    end

    def prompt_builder = Thingie::PromptBuilder.new(@config)

    def tools
      @tools ||= [Thingie::FileTool.new(root: @changeset.workdir), Thingie::SearchTool.new(root: @changeset.workdir)]
    end

    def dedupe(issues)
      settings = @config['dedupe']
      return issues unless settings.is_a?(Hash) && settings['enabled'] && issues.size > 1

      Thingie::DuplicateFilter.new(llm_client: Thingie::LlmClient.new(@config), prompt_builder: prompt_builder)
                              .call(issues, [])
    end

    def with_env(vars)
      previous = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      vars.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
  end

  # Matches each finding to a label with the review model, one call per finding: given the whole list at once,
  # the model drifted and paired findings with the label next to the right one.
  class Scorer
    SCHEMA = {
      name: 'bench_match',
      description: 'The label describing the same defect as the finding, or null',
      strict: true,
      schema: {
        type: 'object',
        properties: { label: { type: %w[integer null] } },
        required: %w[label],
        additionalProperties: false
      }
    }.freeze

    def initialize(config, labels)
      @client = Thingie::LlmClient.new(config)
      @labels = labels
    end

    # @return [Array<Hash, nil>] the label each finding describes, in finding order
    def match(findings)
      return [] if findings.empty?

      Sync { findings.map { |finding| Async { label_for(finding) } }.map(&:wait) }
    end

    private

    def label_for(finding)
      content = @client.complete_with_schema(prompt(finding), SCHEMA).content
      content = Thingie::JsonExtractor.parse(content) if content.is_a?(String)
      index = Integer(content && content['label'], exception: false)
      index&.between?(1, @labels.size) ? @labels[index - 1] : nil
    end

    def prompt(finding)
      <<~PROMPT
        Below are labelled code review findings for one pull request, then one new finding from a reviewer.
        Give the number of the labelled finding that describes the same defect: the same problem in the same
        place, even if worded differently. A different problem in the same file is not a match. Use null when
        no labelled finding describes it.

        LABELLED FINDINGS
        #{@labels.each_with_index.map { |l, i| "#{i + 1}. #{l['file']}: #{l['title']}#{" (#{l['note'].to_s.strip})" if l['note']}" }.join("\n")}

        NEW FINDING
        #{finding['file']}: #{finding['title']}
        #{finding['details'].to_s.gsub(/\s+/, ' ')[0, 800]}
      PROMPT
    end
  end

  # The five dimensions for one review, from the scored findings and the run's measurements. Pure, so the
  # specs cover it without a model.
  module Metrics # rubocop:disable Metrics/ModuleLength
    module_function

    # @param labels [Array<Hash>] the case's labels for this ref
    # @param posted [Array<Hash>] posted findings, each with 'severity', 'confidence', 'unchecked' and 'label'
    #   (the matched label hash, or nil)
    def compute(labels:, posted:, held_back:, usage:, seconds:, changed_lines:, warnings:)
      reals = labels.select { |label| label['label'] == 'real' }
      {
        'quality' => {
          'real_recall' => { 'found' => matched(posted, 'real').size, 'total' => reals.size },
          'first_push_recall' => nil,
          'reals_held_back' => matched(held_back, 'real').size
        },
        'noise' => noise(posted, changed_lines),
        'calibration' => calibration(posted),
        'latency' => { 'seconds' => seconds.round, 'unchecked' => posted.count { |f| f['unchecked'] },
                       'critic_timeouts' => warnings.count { |w| w.include?('Async::TimeoutError') } },
        'cost' => { 'cost_usd' => usage['cost_usd']&.round(2), 'input_tokens' => usage['input_tokens'],
                    'output_tokens' => usage['output_tokens'] }
      }
    end

    def noise(posted, changed_lines)
      counts = posted.group_by { |f| f.dig('label', 'label') || 'unlabelled' }.transform_values(&:size)
      reals = posted.filter_map { |f| f['label'] }.select { |l| l['label'] == 'real' }
      {
        'posted' => posted.size,
        'nit' => counts.fetch('nit', 0), 'wrong' => counts.fetch('wrong', 0),
        'unlabelled' => counts.fetch('unlabelled', 0),
        'nit_rate' => rate(counts.fetch('nit', 0), posted.size),
        'wrong_rate' => rate(counts.fetch('wrong', 0), posted.size),
        'changed_lines' => changed_lines,
        'threads_per_100_lines' => per_hundred_lines(posted.size, changed_lines),
        'duplicates' => reals.size - reals.uniq.size
      }
    end

    def calibration(posted)
      highs = posted.select { |f| f['severity'].to_i.between?(1, 2) }
      mediums = posted.select { |f| f['severity'].to_i == 3 }
      {
        'highs_real' => { 'real' => highs.count { |f| f.dig('label', 'label') == 'real' }, 'total' => highs.size },
        'mediums_nit' => { 'nit' => mediums.count { |f| f.dig('label', 'label') == 'nit' }, 'total' => mediums.size },
        'conf3_posted' => posted.count { |f| f['confidence'].to_i >= 3 }
      }
    end

    # Sums the counts over several reviews and recomputes the rates, so a run over many cases reads like one
    # review. A measurement no review has (cost without pricing) stays nil rather than reading as zero.
    def total(metrics_list)
      return nil if metrics_list.empty?

      sum = ->(*path) { metrics_list.sum { |m| m.dig(*path).to_i } }
      maybe = ->(*path) { (values = metrics_list.filter_map { |m| m.dig(*path) }).empty? ? nil : values.sum }
      posted = sum.call('noise', 'posted')
      lines = sum.call('noise', 'changed_lines')
      {
        'quality' => {
          'real_recall' => { 'found' => sum.call('quality', 'real_recall', 'found'),
                             'total' => sum.call('quality', 'real_recall', 'total') },
          'first_push_recall' => metrics_list.any? { |m| m.dig('quality', 'first_push_recall') } &&
            { 'found' => sum.call('quality', 'first_push_recall', 'found'),
              'total' => sum.call('quality', 'first_push_recall', 'total') },
          'reals_held_back' => sum.call('quality', 'reals_held_back')
        },
        'noise' => {
          'posted' => posted, 'nit' => sum.call('noise', 'nit'), 'wrong' => sum.call('noise', 'wrong'),
          'unlabelled' => sum.call('noise', 'unlabelled'),
          'nit_rate' => rate(sum.call('noise', 'nit'), posted),
          'wrong_rate' => rate(sum.call('noise', 'wrong'), posted),
          'changed_lines' => lines,
          'threads_per_100_lines' => per_hundred_lines(posted, lines),
          'duplicates' => sum.call('noise', 'duplicates')
        },
        'calibration' => {
          'highs_real' => { 'real' => sum.call('calibration', 'highs_real', 'real'),
                            'total' => sum.call('calibration', 'highs_real', 'total') },
          'mediums_nit' => { 'nit' => sum.call('calibration', 'mediums_nit', 'nit'),
                             'total' => sum.call('calibration', 'mediums_nit', 'total') },
          'conf3_posted' => sum.call('calibration', 'conf3_posted')
        },
        'latency' => { 'seconds' => sum.call('latency', 'seconds'), 'unchecked' => sum.call('latency', 'unchecked'),
                       'critic_timeouts' => sum.call('latency', 'critic_timeouts') },
        'cost' => { 'cost_usd' => maybe.call('cost', 'cost_usd')&.round(2),
                    'input_tokens' => maybe.call('cost', 'input_tokens'),
                    'output_tokens' => maybe.call('cost', 'output_tokens') }
      }
    end

    # The mean of several totals (one per repeat), leaf by leaf, so a repeated run reads like one run of it.
    def mean(totals_list)
      return totals_list.first if totals_list.size <= 1

      first = totals_list.first
      return nil if first.nil?

      first.to_h do |key, value|
        values = totals_list.map { |t| t&.dig(key) }
        [key, value.is_a?(Hash) ? mean(values) : mean_value(values)]
      end
    end

    def mean_value(values)
      numbers = values.grep(Numeric)
      return values.first if numbers.empty?

      avg = numbers.sum.to_f / numbers.size
      avg == avg.round ? avg.round : avg.round(1)
    end

    def per_hundred_lines(posted, changed_lines)
      changed_lines.zero? ? nil : (posted * 100.0 / changed_lines).round(1)
    end

    def matched(findings, label)
      findings.filter_map { |f| f['label'] }.select { |l| l['label'] == label }.uniq
    end

    def rate(part, whole)
      whole.zero? ? nil : (part * 100.0 / whole).round
    end
  end

  # A run file from its reviews: one entry per case, ref and repeat.
  module RunFile
    module_function

    # Several run files (one case each, as CI produces them) as one: their reviews together, the first file's
    # provenance, totals recomputed.
    #
    # @param run_files [Array<Hash>] parsed run files
    # @param label [String] the merged run's label
    # @return [Hash] a run file
    def merge(run_files, label:)
      reviews = run_files.flat_map { |run| run['cases'] }
      assemble(reviews, label: label)
        .merge(run_files.first.slice('at', 'sha', 'variant', 'thingie', 'model', 'critic_model'))
    end

    # @param reviews [Array<Hash>] each with 'case', 'ref', 'repeat' and 'metrics'
    # @return [Hash] 'label', 'totals' (the mean over repeats of the final-push totals), 'spread' (each repeat's
    #   totals, when there was more than one) and 'cases'
    def assemble(reviews, label:)
      fold_first_push(reviews)
      repeats = reviews.group_by { |r| r['repeat'].to_i }.values.map { |r| head_totals(r) }
      { 'label' => label, 'totals' => Metrics.mean(repeats),
        'spread' => (repeats if repeats.size > 1), 'cases' => reviews }
    end

    def head_totals(reviews)
      Metrics.total(reviews.select { |r| r['ref'] == 'final-push' }.map { |r| r['metrics'] })
    end

    # The first push's recall goes on the final-push row of the same case and repeat, so the totals (which
    # are over final-push reviews) carry it too. The cases table still shows both rows.
    def fold_first_push(reviews)
      reviews.select { |r| r['ref'] == 'first-push' }.each do |first|
        final = reviews.find do |r|
          r['ref'] == 'final-push' && r['case'] == first['case'] && r['repeat'].to_i == first['repeat'].to_i
        end
        final['metrics']['quality']['first_push_recall'] = first['metrics']['quality']['real_recall'] if final
      end
      reviews
    end
  end

  # The one-page table: the headline row for a run, against a baseline when there is one, then each
  # dimension, then each case.
  module Report # rubocop:disable Metrics/ModuleLength
    module_function

    HEADLINE = [
      ['Real recall', ->(t) { fraction(t.dig('quality', 'real_recall')) }, :up],
      ['Nit rate', ->(t) { pct(t.dig('noise', 'nit_rate')) }, :down],
      ['Wrong rate', ->(t) { pct(t.dig('noise', 'wrong_rate')) }, :down],
      ['Minutes', ->(t) { (t.dig('latency', 'seconds').to_f / 60).round(1) }, :down],
      ['Dollars', ->(t) { t.dig('cost', 'cost_usd') }, :down]
    ].freeze

    DIMENSIONS = {
      'Quality' => [
        ['Real recall', ->(t) { fraction(t.dig('quality', 'real_recall')) }],
        ['Caught at the first push', ->(t) { fraction(t.dig('quality', 'first_push_recall')) }],
        ['Reals held back', ->(t) { t.dig('quality', 'reals_held_back') }]
      ],
      'Noise' => [
        ['Threads', ->(t) { t.dig('noise', 'posted') }],
        ['Nits', ->(t) { t.dig('noise', 'nit') }],
        ['Wrong', ->(t) { t.dig('noise', 'wrong') }],
        ['Unlabelled', ->(t) { t.dig('noise', 'unlabelled') }],
        ['Threads per 100 changed lines', ->(t) { t.dig('noise', 'threads_per_100_lines') }],
        ['Duplicate threads on one bug', ->(t) { t.dig('noise', 'duplicates') }]
      ],
      'Calibration' => [
        ['Highs that are real', ->(t) { fraction(t.dig('calibration', 'highs_real'), 'real') }],
        ['Mediums that are nits', ->(t) { fraction(t.dig('calibration', 'mediums_nit'), 'nit') }],
        ['Confidence 3 posted', ->(t) { t.dig('calibration', 'conf3_posted') }]
      ],
      'Latency' => [
        ['Seconds', ->(t) { t.dig('latency', 'seconds') }],
        ['Unchecked (critic timed out)', ->(t) { t.dig('latency', 'unchecked') }],
        ['Critic timeouts', ->(t) { t.dig('latency', 'critic_timeouts') }]
      ],
      'Cost' => [
        ['Dollars', ->(t) { t.dig('cost', 'cost_usd') }],
        ['Input tokens', ->(t) { t.dig('cost', 'input_tokens') }],
        ['Output tokens', ->(t) { t.dig('cost', 'output_tokens') }]
      ]
    }.freeze

    # @param run [Hash] a run file: 'label', 'totals', 'spread' (per-repeat totals when repeated), 'cases'
    # @param baseline [Hash, nil] another run file to compare against
    # @return [String] Markdown
    def render(run, baseline: nil)
      title = "## Eval results\n\n#{provenance(run, baseline)}"
      return "#{title}\n\nNo final-push reviews in this run." unless run['totals']

      baseline = nil if baseline && !baseline['totals']
      out = [title, '', headline(run, baseline), '']
      DIMENSIONS.each do |name, rows|
        out << "### #{name}" << '' << table(rows, run, baseline) << ''
      end
      out << '### Cases' << '' << cases(run)
      out.join("\n")
    end

    # "`abc1234` against `main` on z-ai/glm-5.3 (critic z-ai/glm-5.3-flash), Thingie 0.11.0"
    def provenance(run, baseline)
      models = run['model'].to_s
      models += " (critic #{run['critic_model']})" if run['critic_model']
      line = ["`#{run['label']}`"]
      line << "against `#{baseline['label']}`" if baseline
      text = line.join(' ')
      text += " on #{models}" unless models.empty?
      text += ", Thingie #{run['thingie']}" if run['thingie']
      text
    end

    def headline(run, baseline)
      head = ['Headline', baseline && baseline['label'], run['label'], baseline && 'Change'].compact
      lines = [row(head), row(head.map { '---' })]
      HEADLINE.each do |name, value, better|
        mine = value.call(run['totals'])
        theirs = baseline && value.call(baseline['totals'])
        cells = [name]
        cells << cell(with_spread(theirs, baseline, value)) if baseline
        cells << cell(with_spread(mine, run, value))
        cells << change(mine, theirs, better) if baseline
        lines << row(cells)
      end
      lines.join("\n")
    end

    def table(rows, run, baseline)
      head = ['', baseline && baseline['label'], run['label']].compact
      lines = [row(head), row(head.map { '---' })]
      rows.each do |name, value|
        cells = [name]
        cells << cell(value.call(baseline['totals'])) if baseline
        cells << cell(value.call(run['totals']))
        lines << row(cells)
      end
      lines.join("\n")
    end

    def cell(value)
      value.nil? || value.to_s.empty? ? '-' : value.to_s
    end

    def cases(run)
      head = %w[Case Ref Real Nit Wrong Threads Seconds Dollars]
      lines = [row(head), row(head.map { '---' })]
      run['cases'].each do |c|
        m = c['metrics']
        lines << row([c['case'], c['ref'], fraction(m.dig('quality', 'real_recall')), m.dig('noise', 'nit'),
                      m.dig('noise', 'wrong'), m.dig('noise', 'posted'), m.dig('latency', 'seconds'),
                      m.dig('cost', 'cost_usd')].map { |v| cell(v) })
      end
      lines.join("\n")
    end

    # "12/20 (11/20..13/20)" when the run was repeated: the extremes of the per-repeat totals.
    def with_spread(value, run, extractor)
      return nil if value.nil?

      spread = Array(run['spread']).compact.map { |t| extractor.call(t) }.compact.uniq
      return value.to_s if spread.size <= 1

      ends = spread.minmax_by { |v| numeric(v) || 0 }.map { |v| v.to_s.delete_suffix('%') }
      "#{value} (#{ends.join('..')})"
    end

    def change(mine, theirs, better)
      a = numeric(mine)
      b = numeric(theirs)
      return '-' if a.nil? || b.nil?

      delta = (a - b).round(2)
      return 'same' if delta.zero?

      good = better == :up ? delta.positive? : delta.negative?
      "#{'+' if delta.positive?}#{delta} #{good ? 'better' : 'worse'}"
    end

    def numeric(value)
      case value
      when Numeric then value
      when %r{\A([\d.]+)/([\d.]+)} then fraction_value(Regexp.last_match(1), Regexp.last_match(2))
      when /\A(\d+)%/ then Regexp.last_match(1).to_i
      end
    end

    def fraction_value(numerator, denominator)
      denominator.to_f.zero? ? nil : numerator.to_f / denominator.to_i
    end

    def fraction(pair, key = 'found')
      return nil unless pair

      "#{pair[key]}/#{pair['total']}"
    end

    def pct(value)
      value && "#{value}%"
    end

    def row(cells)
      "| #{cells.join(' | ')} |"
    end
  end
end
