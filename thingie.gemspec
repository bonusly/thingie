# frozen_string_literal: true

require_relative 'lib/thingie/version'

Gem::Specification.new do |spec|
  spec.name = 'thingie'
  spec.version = Thingie::VERSION
  spec.authors = ['Bonusly Engineering']
  spec.email = ['engineering@bonus.ly']

  spec.summary = 'Thingie: approves pull requests that GitHub Copilot approved'
  spec.description = 'A deterministic pull request auto-approver. Thingie approves a PR when ' \
                     "GitHub Copilot's latest review approves the PR's current commit and a set " \
                     'of safety rules (protected paths, change size, obfuscated code, ...) all pass.'
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

  # GitHub API
  spec.add_dependency 'octokit', '~> 10.0'

  # Configuration
  spec.add_dependency 'dotenv', '~> 3.1'
  spec.add_dependency 'tomlrb', '~> 2.0'
end
