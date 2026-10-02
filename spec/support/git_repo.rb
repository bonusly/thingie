# frozen_string_literal: true

require 'fileutils'
require 'open3'

# Builds a throwaway git repository for specs that need a real diff.
module GitRepo
  def git_write(repo, path, content)
    full = File.join(repo, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def git_commit(repo, message)
    git(repo, 'add', '-A')
    git(repo, '-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '--allow-empty', '-m', message)
  end

  def git(repo, *args)
    _out, err, status = Open3.capture3('git', '-C', repo, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
  end
end
