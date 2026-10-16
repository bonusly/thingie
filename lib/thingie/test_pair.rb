# frozen_string_literal: true

module Thingie
  # Pairs a spec with the code it tests, so neither is reviewed blind. A spec
  # reviewed on its own has nothing to check against, so the model reports the
  # code's defects on the spec and test gaps that are covered elsewhere; code
  # reviewed without its tests cannot tell what the change set out to do.
  # Companions come from the whole diff, so a subject matched by `exclude_files`
  # still shows up beside its spec.
  class TestPair
    # Past this the companion crowds the file under review out of the prompt.
    MAX_LINES = 2_000
    MAX_BYTES = 100_000

    # Builds the pairing for one changeset.
    #
    # @param changeset [Thingie::Changeset] the diff under review
    def initialize(changeset)
      @changeset = changeset
    end

    # The prompt section for a file's companion: the code a spec tests, or the
    # spec of a file when that spec changed in the same PR.
    #
    # @param file [String] repo-relative path of the file under review
    # @return [String] the rendered section, or '' when the file has no companion
    def section_for(file)
      return '' if @changeset.all?

      if spec?(file)
        subject = subject_for(file)
        subject && exists?(file) ? subject_section(subject) : ''
      else
        spec = spec_for(file)
        spec ? spec_section(spec) : ''
      end
    end

    # The file a spec tests, by convention: `spec/lib/x_spec.rb` tests
    # `app/lib/x.rb` or `lib/x.rb`, `spec/models/x_spec.rb` tests `app/models/x.rb`,
    # and in a gem `spec/thingie/x_spec.rb` tests `lib/thingie/x.rb`.
    #
    # @param spec [String] repo-relative path of the spec
    # @return [String, nil] the path, or nil when no candidate exists at the reviewed commit
    def subject_for(spec)
      rest = spec.delete_prefix('spec/').delete_suffix('_spec.rb')
      ["app/#{rest}.rb", "#{rest}.rb", "lib/#{rest}.rb"].find { |path| exists?(path) }
    end

    # The spec of a file, when that spec changed in the same PR: the inverse of
    # {#subject_for}, over the same layouts.
    #
    # @param subject [String] repo-relative path of the file
    # @return [String, nil] the path, or nil when no spec of it is in the diff
    def spec_for(subject)
      return nil unless subject.end_with?('.rb')

      rest = subject.delete_suffix('.rb')
      candidates = [rest.delete_prefix('app/'), rest.delete_prefix('lib/'), rest].uniq
      candidates.map { |path| "spec/#{path}_spec.rb" }.find { |path| changed?(path) }
    end

    private

    def spec?(file)
      file.start_with?('spec/') && file.end_with?('_spec.rb')
    end

    def exists?(path)
      !@changeset.full_content_for(path).nil?
    end

    def changed?(path)
      !@changeset.diff_text_for(path).nil?
    end

    def subject_section(subject)
      changed = changed?(subject) ? ', also changed in this PR' : ''
      <<~TEXT.chomp
        The code these tests exercise: #{subject}#{changed}.
        Report only problems with the tests: a test that passes while this code is wrong, or a
        behaviour this PR changes that no test covers. A defect in the code itself belongs to that
        file's review; do not report it here.
        #{capped(@changeset.full_content_for(subject))}
      TEXT
    end

    def spec_section(spec)
      <<~TEXT.chomp
        The tests for this file, changed in this PR: #{spec}.
        Use them to see what the change is meant to do and what it leaves unchecked.
        #{capped(@changeset.diff_text_for(spec))}
      TEXT
    end

    def capped(text)
      lines = text.lines
      return text if lines.size <= MAX_LINES && text.bytesize <= MAX_BYTES

      kept = +''
      lines.first(MAX_LINES).each do |line|
        break if kept.bytesize + line.bytesize > MAX_BYTES

        kept << line
      end
      "#{kept}[cut after #{kept.lines.size} lines]"
    end
  end
end
