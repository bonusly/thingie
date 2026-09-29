# frozen_string_literal: true

require_relative 'lib/thingie/version'

Gem::Specification.new do |spec|
  spec.name = 'thingie'
  spec.version = Thingie::VERSION
  spec.authors = ['Bonusly Engineering']
  spec.email = ['engineering@bonus.ly']

  spec.summary = 'Thingie: Ruby (but mostly Rails) Review Thing'
  spec.description = 'An opinionated, flexible AI code review tool for Ruby and Rails projects. ' \
                     'Inspired by Gito, thingie reviews pull requests using LLMs, pulling extra ' \
                     'context from language servers (LSP) and posting feedback on changed lines.'
  spec.homepage = 'https://github.com/Bonusly/rubyrt'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/Bonusly/rubyrt'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/Bonusly/rubyrt/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:test|spec|features)/})
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # CLI
  spec.add_dependency 'thor', '~> 1.3'

  # LLM abstraction. Runs on ruby_llm 1.16 or 2.x (see Thingie::LlmCompat). A
  # 2.x bundle also needs ruby_llm-skills 0.5.0.pre1 and a 2.x-compatible
  # ruby_llm-mcp (patvice/ruby_llm-mcp#161 until it is released).
  spec.add_dependency 'ruby_llm', '>= 1.16', '< 3'
  spec.add_dependency 'ruby_llm-mcp', '>= 1.0', '< 2'
  spec.add_dependency 'ruby_llm-skills', '>= 0.3.0', '< 1'

  # Git access
  spec.add_dependency 'rugged', '~> 1.9'

  # Async reviews
  spec.add_dependency 'async', '~> 2.40'

  # GitHub API
  spec.add_dependency 'octokit', '~> 10.0'

  # Configuration / templating
  spec.add_dependency 'dotenv', '~> 3.1'
  spec.add_dependency 'tomlrb', '~> 2.0'
end
