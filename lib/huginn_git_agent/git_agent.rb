module Agents

  class GitAgent < Agent
    default_schedule '12h'
    gem_dependency_check { defined?(Git) }

    description <<-MD
      Creates an event with metadata and difference metadata from a git repository.
      
      This agent only clones/fetches the *bare* repository. It does not clone/fetch the contetents of the repository.

      On the first run the agent will clone the bare repository. On subsequent runs it will load the repository state, fetch the bare repository, and compare the before and after states. If there is no change the commits shown will be the last commit in the context (last in the repository or last in the branch).

      Currently only unauthenticated repositories are supported.

      Both the `repository` and `path` options are required. The parent directory of `path` must already exist.

      ## Event Details
      ### Repo fields
      * changed (bool): `true` if changes were detected.
      * diff_stats (hash): Various stats based on the diff of the previous last
        commit and the current last commit in the repository.
      * current_tags (list): A list of tag metadata for the tags in the current
        repository state.
      * new_tags (list): A list of tag names added since the previous
        repository state.
      * removed_tags (list): A list of tag names removed since the previous 
        repository state.
      * current_branches (list): A list of branch metadata for the branches in
        the current repository state.
      * new_branches (list): A list of branch names added since the previous
        repository state.
      * removed_branches (list): A list of branch names removed since the 
        previous repository state.
      * log (list): A list of commit metadata. The list is the git log from the
        previous last commit in the entire repo to the current last commit in
        the repo, independent of branches.

      ### Branch Metadata
      * changed (bool): `true` if changes were detected for the branch.
      * name: The name of the branch.
      * prev_last_commit: The commit metadata for the previous branch head.
      * new_last_commit: The commit metadata for the current branch head.
      * log (list): A list of commit metadata. The list is the git log from the
        previous last commit in the branch to the current last commit in
        the branch.
      * diff_stats: Various stats based on the diff of the previous last
        commit and the current last commit in the branch.

      ### Commit Metadata
      * sha: The commit hash.
      * message: The commit message.
      * author: The author's name and email `{'name' => commit.author.name, 'email' => commit.author.email}`.
      * date: The date of the commit.

      ### Tag
      * sha: The hash of the tagged commit. This is the original hash if the commit was moved.
      * name: The name of the commit.
      * moved_to: If the tag was moved between the previous repository state
        and the current state this is the hash of the commit that the tag was moved to.
    MD

    event_description <<-MD
      {
        "changed": false,
        "diff_stats": {
          "total": {
            "insertions": 0,
            "deletions": 0,
            "lines": 0,
            "files": 0
          },
          "files": {}
        },
        "current_tags": [],
        "new_tags": [],
        "removed_tags": [],
        "current_branches": [
          {
            "changed": false,
            "name": "main",
            "prev_last_commit": {
              "sha": "3ee61607555471379fa83207dec167f521b772dd",
              "message": "Works. Lightly tested. Also some cleanup.",
              "author": {
                "name": "haxwithaxe",
                "email": "spam@haxwithaxe.net"
              },
              "date": "2022-05-26 07:29:59 -0700"
            },
            "new_last_commit": {
              "sha": "3ee61607555471379fa83207dec167f521b772dd",
              "message": "Works. Lightly tested. Also some cleanup.",
              "author": {
                "name": "haxwithaxe",
                "email": "spam@haxwithaxe.net"
              },
              "date": "2022-05-26 07:29:59 -0700"
            },
            "log": [
              {
                "sha": "3ee61607555471379fa83207dec167f521b772dd",
                "message": "Works. Lightly tested. Also some cleanup.",
                "author": {
                  "name": "haxwithaxe",
                  "email": "spam@haxwithaxe.net"
                },
                "date": "2022-05-26 07:29:59 -0700"
              }
            ],
            "diff_stats": {
              "total": {
                "insertions": 0,
                "deletions": 0,
                "lines": 0,
                "files": 0
              },
              "files": {}
            }
          }
        ],
        "new_branches": [],
        "removed_branches": [],
        "log": []
      }
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
      checked_without_error?
    end

    def recieve(incoming_events)
      incoming_events.each do |event|
        handle(interpolated(event), event)
      end
    end

    def check
      handle(interpolated)
    end

    def handle(opts, event = Event.new)
      log("opts = #{opts.to_s}")
      begin
        metadata = get_metadata(opts['repository'], opts['path'])
      rescue => err
        error("Error getting metadata: #{err.message}")
        return
      end
      create_event payload: metadata
    end

    # Returns the difference between the given repo before and after fetching.
    # The output hash has the following keys:
    # * changed (bool): `true` if changes were detected.
    # * diff_stats (hash): Various stats based on the diff of the previous last
    #   commit and the current last commit.
    # * current_tags (list): A list of tag metadata for the tags in the current
    #   repository state.
    # * new_tags (list): A list of tag names added since the previous
    #   repository state.
    # * removed_tags (list): A list of tag names removed since the previous 
    #   repository state.
    # * current_branches (list): A list of branch metadata for the branches in
    #   the current repository state.
    # * new_branches (list): A list of branch names added since the previous
    #   repository state.
    # * removed_branches (list): A list of branch names removed since the 
    #   previous repository state.
    # * log (list): A list of commit metadata. The list is the git log from the
    #   previous last commit in the entire repo to the current last commit in
    #   the repo, independent of branches.
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
      rescue Git::GitExecuteError => err
        begin
          git = Git.bare(path)
        rescue Git::GitExecuteError => err
          error "Error opening bare repo #{repo} in #{path}: #{err.message}"
          return
        end
      end
      before = RepoState.new(git)
      begin
        git.fetch(repo, ref: '*:*', force: true, tags: true)
      rescue Git::GitExecuteError => err
        error "Error fetching #{repo} in #{path}: #{err.message}"
        return
      end
      after = RepoState.new(git)
      if after.last_commit
        output['diff_stats'] = git.diff(before.last_commit, after.last_commit).stats
        output['changed'] = before.last_commit.sha != after.last_commit.sha
      else
        output['diff_stats'] = git.diff(before.last_commit, before.last_commit).stats
      end
      branches_diff = diff_branch_lists(before.branches, after.branches)
      output['new_branches'] = branches_diff['added'].map { |b| b.to_h }
      output['removed_branches'] = branches_diff['removed'].map { |b| b.to_h }
      output['current_branches'] = branches_diff['reconciled'].map { |b| b.to_h }
      output['changed'] = branches_diff['changed'] or output['changed']
      tags_diff = diff_tag_lists(before.tags, after.tags)
      output['new_tags'] = tags_diff['added'].map { |t| t.to_h }
      output['removed_tags'] = tags_diff['removed'].map { |t| t.to_h }
      output['current_tags'] = tags_diff['reconciled'].map { |t| t.to_h }
      output['changed'] = tags_diff['changed'] or output['changed']
      return output
    end

    # Returns a hash of the difference between two lists of `Tag` instances
    # The hash has four keys:
    # * changed (bool): `true` if changes were detected
    # * added (list): A list of `Tag` instances that are in `after` but not `before`.
    # * removed (list): A list of `Tag` instances that are in `before` but not `after`.
    # * reconsiled (list): A list of `Tag` instances that are in both `before` 
    #   and `after`. These are the matching `before` tags fed the corresponding
    #   `after` tags to detect changed tag hashes.
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

    # Returns the difference between two lists of `Branch` instances
    # The hash has four keys:
    # * changed (bool): `true` if changes were detected
    # * added (list): A list of `Branch` instances that are in `after` but not `before`.
    # * removed (list): A list of `Branch` instances that are in `before` but not `after`.
    # * reconsiled (list): A list of `Branch` instances that are in both `before` 
    #   and `after`. These are the matching `before` branchs fed the corresponding
    #   `after` branchs to detect changed branch hashes.
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

    # Git tag model
    class Tag
      
      # Takes a Git::Tag instance as an argument
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

      # Update the state of the tag to reflect a change in tag commit.
      # Takes a `Tag` instance as an argument.
      def update(other)
        if @name == other.name and @sha != other.sha
          @moved_to = other.sha
        end
        return self
      end

    end


    # Git branch model
    class Branch
      
      # Takes a `Git::Branch` instance as an argument.
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

      # Update the state of the branch to reflect a change in branch HEAD.
      # Takes a `Branch` instance as an argument.
      def update(branch)
        @updated_last_commit = branch.last_commit
        return self
      end

      def commit_to_hash(commit)
        if not commit
          return nil
        end
        {'sha' => commit.sha.sub('warning: refname \'HEAD\' is ambiguous.\n', ''), 'message' => commit.message, 
         'author' => {'name' => commit.author.name, 'email' => commit.author.email},
         'date' => commit.date.to_s}
      end

      def log_for_commits(before_commit, after_commit)
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

      def to_h
        # Get the diff stats even if there is no change
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
          'log' => self.log_for_commits(@last_commit, @updated_last_commit),
          'diff_stats' => diff_stats
        }
      end

    end

    # Repository state snapshot
    class RepoState

      # Takes a `Git::Base` instance as an argument
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

  end
end
