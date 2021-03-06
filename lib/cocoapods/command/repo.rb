require 'fileutils'

module Pod
  class Command
    class Repo < Command
      self.abstract_command = true

      # @todo should not show a usage banner!
      #
      self.summary = 'Manage spec-repositories'
      self.default_subcommand = 'list'

      class Add < Repo
        self.summary = 'Add a spec repo.'

        self.description = <<-DESC
          Clones `URL` in the local spec-repos directory at `~/.cocoapods/repos/`. The
          remote can later be referred to by `NAME`.
        DESC

        self.arguments = 'NAME URL [BRANCH]'

        def initialize(argv)
          @name, @url, @branch = argv.shift_argument, argv.shift_argument, argv.shift_argument
          super
        end

        def validate!
          super
          unless @name && @url
            help! "Adding a repo needs a `NAME` and a `URL`."
          end
        end

        def run
          UI.section("Cloning spec repo `#{@name}` from `#{@url}`#{" (branch `#{@branch}`)" if @branch}") do
            config.repos_dir.mkpath
            Dir.chdir(config.repos_dir) { git!("clone '#{@url}' #{@name}") }
            Dir.chdir(dir) { git!("checkout #{@branch}") } if @branch
            SourcesManager.check_version_information(dir)
          end
        end
      end

      #-----------------------------------------------------------------------#

      class Update < Repo
        self.summary = 'Update a spec repo.'

        self.description = <<-DESC
          Updates the local clone of the spec-repo `NAME`. If `NAME` is omitted
          this will update all spec-repos in `~/.cocoapods/repos`.
        DESC

        self.arguments = '[NAME]'

        def initialize(argv)
          @name = argv.shift_argument
          super
        end

        def run
          SourcesManager.update(@name, true)
        end
      end

      #-----------------------------------------------------------------------#

      class Lint < Repo
        self.summary = 'Validates all specs in a repo.'

        self.description = <<-DESC
          Lints the spec-repo `NAME`. If a directory is provided it is assumed
          to be the root of a repo. Finally, if `NAME` is not provided this
          will lint all the spec-repos known to CocoaPods.
        DESC

        self.arguments = '[ NAME | DIRECTORY ]'

        def self.options
          [["--only-errors", "Lint presents only the errors"]].concat(super)
        end

        def initialize(argv)
          @name = argv.shift_argument
          @only_errors = argv.flag?('only-errors')
          super
        end

        # @todo Part of this logic needs to be ported to cocoapods-core so web
        #       services can validate the repo.
        #
        # @todo add UI.print and enable print statements again.
        #
        def run
          if @name
            dirs = File.exists?(@name) ? [ Pathname.new(@name) ] : [ dir ]
          else
            dirs = SourcesManager.aggregate.all
          end
          dirs.each do |dir|
            SourcesManager.check_version_information(dir)
            UI.puts "\nLinting spec repo `#{dir.realpath.basename}`\n".yellow

            validator = Source::HealthReporter.new(dir)
            validator.pre_check do |name, version|
              UI.print '.'
            end
            report = validator.analyze
            UI.puts
            UI.puts

            report.pods_by_warning.each do |message, versions_by_name|
              UI.puts "-> #{message}".yellow
              versions_by_name.each { |name, versions| UI.puts "  - #{name} (#{versions * ', '})" }
              UI.puts
            end

            report.pods_by_error.each do |message, versions_by_name|
              UI.puts "-> #{message}".red
              versions_by_name.each { |name, versions| UI.puts "  - #{name} (#{versions * ', '})" }
              UI.puts
            end

            UI.puts "Analyzed #{report.analyzed_paths.count} podspecs files.\n\n"
            if report.pods_by_error.count.zero?
              UI.puts "All the specs passed validation.".green << "\n\n"
            else
              raise Informative, "#{report.pods_by_error.count} podspecs failed validation."
            end
          end
        end
      end

      #-----------------------------------------------------------------------#

      class Remove < Repo
        self.summary = 'Remove a spec repo'

        self.description = <<-DESC
          Deletes the remote named `NAME` from the local spec-repos directory at `~/.cocoapods/repos/.`
        DESC

        self.arguments = 'NAME'

        def initialize(argv)
          @name = argv.shift_argument
          super
        end

        def validate!
          super
          help! 'Deleting a repo needs a `NAME`.' unless @name
          help! "repo #{@name} does not exist" unless File.directory?(dir)
        end

        def run
          UI.section("Removing spec repo `#{@name}`") do
            FileUtils.rm_rf(dir)
          end
        end
      end
      
      #-----------------------------------------------------------------------#
      
      class List < Repo
        self.summary = 'List repos'
          
        self.description = <<-DESC
          List the repos from the local spec-repos directory at `~/.cocoapods/repos/.`
        DESC

        def self.options
          [["--count", "Shows the total number of spec repos"]].concat(super)
        end

        def initialize(argv)
          @count = argv.flag?('count')
          super
        end

        # @output  Examples:
        #
        #          master
        #          - type: git (origin)
        #          - URL:  https://github.com/CocoaPods/Specs.git
        #          - path: /Users/lascorbe/.cocoapods/repos/master
        #
        #          test
        #          - type: local copy
        #          - path: /Users/lascorbe/.cocoapods/repos/test
        #
        def run
          dirs = SourcesManager.aggregate.all
          dirs.each do |source|
            path = source.repo
            UI.title source.name do
              Dir.chdir(path) do
                if SourcesManager.git_repo?(path)
                  branch_name = get_branch_name
                  remote_name = get_branch_remote_name(branch_name)
                  if remote_name
                    UI.puts "- type: git (#{remote_name})"
                    url = get_url_of_git_repo(remote_name)
                    UI.puts "- URL:  #{url}"
                  else
                    UI.puts "- type: git (no remote information available)"
                  end
                else
                  UI.puts "- type: local copy"
                end
                UI.puts "- path: #{path}"
              end
            end
          end
          if @count
            number_of_repos = dirs.length
            repo_string = number_of_repos != 1 ? 'repos' : 'repo'
            UI.puts "\n#{number_of_repos} #{repo_string}\n"
          end
        end
      end

      extend Executable
      executable :git

      def dir
        config.repos_dir + @name
      end

      # Returns the branch name (i.e. master)
      #
      def get_branch_name
        branch_name = git!("name-rev --name-only HEAD")
        branch_name.strip
      end

      # Returns the branch remote name (i.e. origin)
      #
      # @param  [BranchName] branch_name
      #         The branch name to look for the remote name.
      #
      def get_branch_remote_name(branch_name)
        p branch_name
        remote_name = git!("config branch.#{branch_name}.remote")
        remote_name.strip
      end

      # Returns the url of the given remote name (i.e. git@github.com:CocoaPods/Specs.git)
      #
      # @param  [RemoteName] remote_name
      #         The branch remote name to look for the url.
      #
      def get_url_of_git_repo(remote_name)
        git!("config remote.#{remote_name}.url")
      end
    end
  end
end

