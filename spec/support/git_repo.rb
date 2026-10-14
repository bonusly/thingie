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
    # Ignore the developer's signing config so specs don't need keys or tag messages.
    unsigned = ['-c', 'tag.gpgsign=false', '-c', 'commit.gpgsign=false']
    _out, err, status = Open3.capture3('git', '-C', repo, *unsigned, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
  end
end
