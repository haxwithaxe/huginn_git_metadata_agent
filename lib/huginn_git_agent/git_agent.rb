require 'git'


module Agents
  class GitAgent < Agent
    default_schedule '12h'

    description <<-MD
      Creates an event with metadata from a git repository.
      Both the `repository` and `path` options are required.
    MD

    def default_options
      {
        'repository' => nil,
        'path' => nil
      }
    end

    def validate_options
        errors.add(:base, 'repository is required') unless options['repository'].present?
        errors.add(:base, 'path is required') unless options['path'].present?
    end

    def working?
      # Implement me! Maybe one of these next two lines would be a good fit?
      checked_without_error?
    end

    def check
      begin
        create_event :payload => get_metadata(interpolated['repository'], interpolated['path'])
      rescue error => err
        errors.add(:base, err.message)
      end
    end

  end
end


def commit_to_hash(commit)
  if not commit
    return nil
  end
  {'sha' => commit.sha.sub('warning: refname \'HEAD\' is ambiguous.\n', ''), 'message' => commit.message, 
   'author' => {'name' => commit.author.name, 'email' => commit.author.email},
   'date' => commit.date.to_s}
end


def log(before_commit, after_commit)
  if not after_commit or before_commit.sha == after_commit.sha
    return [commit_to_hash(before_commit)]
  end
  if not before_commit and after_commit
    return [commit_to_hash(after_commit)]
  end
  return after_commit.log.until(before_commit).map { |commit|
    commit_to_hash(commit)
  }
end


class Tag
  
  def initialize(tag)
    @sha = tag.sha
    @name = tag.name
    @moved_to = nil
  end

  def name
    @name
  end

  def sha
    @sha
  end

  def to_h
    return {'sha' => @sha, 'name' => @name, 'moved_to' => @moved_to}
  end

  def update(other)
    if @name == other.name and @sha != other.sha
      @moved_to = other.sha
    end
    return self
  end

end


class Branch
  
  def initialize(git, branch)
    @git = git
    @branch_name = branch.name
    @last_commit = branch.gcommit
    @updated_last_commit = nil
  end

  def last_commit
    @last_commit
  end

  def name
    @branch_name
  end

  def update(branch)
    @updated_last_commit = branch.last_commit
    return self
  end

  def to_h
    if @updated_last_commit
      diff_stats = @git.diff(@last_commit, @updated_last_commit).stats
    else
      diff_stats = @git.diff(@last_commit, @last_commit).stats
    end
    {
      'changed' => @last_commit.sha != @updated_last_commit.sha,
      'name' => @branch_name,
      'prev_last_commit' => commit_to_hash(@last_commit), 
      'new_last_commit' => commit_to_hash(@updated_last_commit), 
      'log' => log(@last_commit, @updated_last_commit),
      'diff_stats' => diff_stats
    }
  end

end

class RepoState

  def initialize(git_obj)
    @branches = []
    @tags = []
    @branches = git_obj.branches.map { |b| Branch.new(git_obj, b) }
    @tags = git_obj.tags.map { |t| Tag.new(t) }
    # The most recent commit of all branches
    @last_commit = self._last_commit() # Must be after @branches init
  end

  def last_commit
    @last_commit
  end

  def _last_commit
    commit = nil
    @branches.each { |branch|
      if not commit
        commit = branch.last_commit
      elsif branch.last_commit.date > commit.date
        commit = branch.last_commit
      end
    }
    return commit
  end

  def branches
    @branches
  end

  def tags
    @tags
  end

end


def diff_tag_lists(before, after)
  added = []
  removed = []
  reconciled = []
  after.each { |a|
    if before.select { |x| x.name == a.name }.empty?
      added.append(a)
      reconciled.append(a)
    end
  }
  before.each { |b|
    if after.select { |x| x.name == b.name }.empty?
      removed.append(b)
    else
      a_arr = after.select { |x| x.name == b.name }
      b.update(a_arr[0])
      reconciled.append(b)
    end
  }
  return {
    'changed' => (not added.empty? or not removed.empty?),
    'added' => added,
    'removed' => removed,
    'reconciled' => reconciled
  }
end

def diff_branch_lists(before, after)
  added = []
  removed = []
  reconciled = []
  after.each { |a|
    if before.select { |x| x.name == a.name }.empty?
      added.append(a)
      reconciled.append(a)
    end
  }
  before.each { |b|
    if after.select { |x| x.name == b.name }.empty?
      removed.append(b)
    else
      a_arr = after.select { |x| x.name == b.name }
      b.update(a_arr[0])
      reconciled.append(b)
    end
  }
  return {
    'changed' => (not added.empty? or not removed.empty?),
    'added' => added,
    'removed' => removed,
    'reconciled' => reconciled
  }
end

def get_metadata(repo, path)
  output = {
    'changed' => false,
    'diff_stats' => {},
    'current_tags' => [], 
    'new_tags' => [],
    'removed_tags' => [],
    'current_branches' => [],
    'new_branches' => [],
    'removed_branches' => [],
    'log' => []
  }
  begin
    git = Git.clone(repo, path, bare: true)
  rescue Git::GitExecuteError
    git = Git.bare(path)
  end
  before = RepoState.new(git)
  git.fetch(repo, ref: '*:*', force: true, tags: true)
  after = RepoState.new(git)
  if after.last_commit
    output['diff_stats'] = git.diff(before.last_commit, after.last_commit).stats
    output['changed'] = before.last_commit.sha != after.last_commit.sha
  else
    output['diff_stats'] = git.diff(before.last_commit, before.last_commit).stats
  end
  git.tags.each { |t| output['current_tags'].append(t.name) }
  branches_diff = diff_branch_lists(before.branches, after.branches)
  output['new_branches'] = branches_diff['added'].map { |b| b.name }
  output['removed_branches'] = branches_diff['removed'].map { |b| b.name }
  output['current_branches'] = branches_diff['reconciled'].map { |b| b.to_h }
  output['changed'] = branches_diff['changed'] or output['changed']
  tags_diff = diff_tag_lists(before.tags, after.tags)
  output['new_tags'] = tags_diff['added'].map { |t| t.name }
  output['removed_tags'] = tags_diff['removed'].map { |t| t.name }
  output['current_tags'] = tags_diff['reconciled'].map { |t| t.to_h }
  output['changed'] = tags_diff['changed'] or output['changed']
  return output
end
