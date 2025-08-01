# typed: strict
# frozen_string_literal: true

require "parallel"
require "sorbet-runtime"
require "dependabot/bundler/language"
require "dependabot/bundler/package_manager"
require "dependabot/dependency"
require "dependabot/file_parsers"
require "dependabot/file_parsers/base"
require "dependabot/bundler/file_updater/lockfile_updater"
require "dependabot/bundler/native_helpers"
require "dependabot/bundler/helpers"
require "dependabot/bundler/version"
require "dependabot/bundler/cached_lockfile_parser"
require "dependabot/shared_helpers"
require "dependabot/errors"

module Dependabot
  module Bundler
    class FileParser < Dependabot::FileParsers::Base # rubocop:disable Metrics/ClassLength
      extend T::Sig
      require "dependabot/file_parsers/base/dependency_set"
      require "dependabot/bundler/file_parser/file_preparer"
      require "dependabot/bundler/file_parser/gemfile_declaration_finder"
      require "dependabot/bundler/file_parser/gemspec_declaration_finder"

      sig { override.returns(T::Array[Dependabot::Dependency]) }
      def parse
        dependency_set = DependencySet.new
        dependency_set += gemfile_dependencies
        dependency_set += gemspec_dependencies
        dependency_set += lockfile_dependencies
        check_external_code(dependency_set.dependencies)
        dependency_set.dependencies
      end

      sig { returns(Ecosystem) }
      def ecosystem
        @ecosystem ||= T.let(
          Ecosystem.new(
            name: ECOSYSTEM,
            package_manager: package_manager,
            language: language
          ),
          T.nilable(Ecosystem)
        )
      end

      private

      sig { returns(Ecosystem::VersionManager) }
      def package_manager
        @package_manager ||= T.let(
          PackageManager.new(
            detected_version: bundler_version,
            raw_version: bundler_raw_version,
            requirement: package_manager_requirement
          ),
          T.nilable(Ecosystem::VersionManager)
        )
      end

      sig { returns(T.nilable(Requirement)) }
      def package_manager_requirement
        @package_manager_requirement ||= T.let(
          Helpers.dependency_requirement(
            Helpers::BUNDLER_GEM_NAME, dependency_files
          ),
          T.nilable(T.nilable(Requirement))
        )
      end

      sig { returns(T.nilable(Ecosystem::VersionManager)) }
      def language
        @language = T.let(@language, T.nilable(Ecosystem::VersionManager))
        return @language if defined?(@language)

        return @language = nil if package_manager.unsupported?

        @language = Language.new(ruby_raw_version, language_requirement)
      end

      sig { returns(T.nilable(Requirement)) }
      def language_requirement
        @language_requirement ||= T.let(
          Helpers.dependency_requirement(
            Helpers::LANGUAGE, dependency_files
          ),
          T.nilable(T.nilable(Requirement))
        )
      end

      sig { params(dependencies: T::Array[Dependabot::Dependency]).void }
      def check_external_code(dependencies)
        return unless @reject_external_code
        return unless git_source?(dependencies)

        # A git source dependency might contain a .gemspec that is evaluated
        raise ::Dependabot::UnexpectedExternalCode
      end

      sig { params(dependencies: T::Array[Dependabot::Dependency]).returns(T::Boolean) }
      def git_source?(dependencies)
        dependencies.any? do |dep|
          dep.requirements.any? { |req| req.fetch(:source)&.fetch(:type) == "git" }
        end
      end

      sig { returns(DependencySet) }
      def gemfile_dependencies
        @gemfile_dependencies = T.let(@gemfile_dependencies, T.nilable(DependencySet))
        return @gemfile_dependencies if @gemfile_dependencies

        dependencies = DependencySet.new

        return (@gemfile_dependencies = dependencies) unless gemfile

        [T.must(gemfile), *evaled_gemfiles].each do |file|
          gemfile_declaration_finder = GemfileDeclarationFinder.new(gemfile: file)

          parsed_gemfile.each do |dep|
            next unless gemfile_declaration_finder.gemfile_includes_dependency?(dep)

            dependencies <<
              Dependency.new(
                name: dep.fetch("name"),
                version: dependency_version(dep.fetch("name"))&.to_s,
                requirements: [{
                  requirement: gemfile_declaration_finder.enhanced_req_string(dep),
                  groups: dep.fetch("groups").map(&:to_sym),
                  source: dep.fetch("source")&.transform_keys(&:to_sym),
                  file: file.name
                }],
                package_manager: "bundler"
              )
          end
        end

        @gemfile_dependencies = dependencies
      end

      sig { returns(DependencySet) }
      def gemspec_dependencies # rubocop:disable Metrics/PerceivedComplexity
        @gemspec_dependencies = T.let(@gemspec_dependencies, T.nilable(DependencySet))
        return @gemspec_dependencies if @gemspec_dependencies

        queue = Queue.new

        SharedHelpers.in_a_temporary_repo_directory(T.must(base_directory), repo_contents_path) do
          write_temporary_dependency_files

          Parallel.map(gemspecs, in_threads: 4) do |gemspec|
            gemspec_declaration_finder = GemspecDeclarationFinder.new(gemspec: gemspec)

            parsed_gemspec(gemspec).each do |dependency|
              next unless gemspec_declaration_finder.gemspec_includes_dependency?(dependency)

              queue << Dependency.new(
                name: dependency.fetch("name"),
                version: dependency_version(dependency.fetch("name"))&.to_s,
                requirements: [{
                  requirement: dependency.fetch("requirement").to_s,
                  groups: if dependency.fetch("type") == "runtime"
                            ["runtime"]
                          else
                            ["development"]
                          end,
                  source: dependency.fetch("source")&.transform_keys(&:to_sym),
                  file: gemspec.name
                }],
                package_manager: "bundler"
              )
            end
          end
        end

        dependency_set = DependencySet.new
        dependency_set << queue.pop(true) while queue.size.positive?
        @gemspec_dependencies = dependency_set
      end

      sig { returns(DependencySet) }
      def lockfile_dependencies
        dependencies = DependencySet.new

        return dependencies unless lockfile

        # Create a DependencySet where each element has no requirement. Any
        # requirements will be added when combining the DependencySet with
        # other DependencySets.
        parsed_lockfile.specs.each do |dependency|
          next if dependency.source.is_a?(::Bundler::Source::Path)

          dependencies <<
            Dependency.new(
              name: dependency.name,
              version: dependency_version(dependency.name)&.to_s,
              requirements: [],
              package_manager: "bundler",
              subdependency_metadata: [{
                production: production_dep_names.include?(dependency.name)
              }]
            )
        end

        dependencies
      end

      sig { returns(T::Array[T::Hash[String, T.untyped]]) }
      def parsed_gemfile
        @parsed_gemfile ||= T.let(
          SharedHelpers.in_a_temporary_repo_directory(T.must(base_directory),
                                                      repo_contents_path) do
            write_temporary_dependency_files

            NativeHelpers.run_bundler_subprocess(
              bundler_version: bundler_version,
              function: "parsed_gemfile",
              options: options,
              args: {
                gemfile_name: T.must(gemfile).name,
                lockfile_name: lockfile&.name,
                dir: Dir.pwd
              }
            )
          end,
          T.nilable(T::Array[T::Hash[String, T.untyped]])
        )
      rescue SharedHelpers::HelperSubprocessFailed => e
        handle_eval_error(e) if e.error_class == "JSON::ParserError"

        msg = e.error_class + " with message: " +
              e.message.force_encoding("UTF-8").encode
        raise Dependabot::DependencyFileNotEvaluatable, msg
      end

      sig { params(err: StandardError).void }
      def handle_eval_error(err)
        msg = "Error evaluating your dependency files: #{err.message}"
        raise Dependabot::DependencyFileNotEvaluatable, msg
      end

      sig { params(file: Dependabot::DependencyFile).returns(T::Array[T::Hash[String, T.untyped]]) }
      def parsed_gemspec(file)
        NativeHelpers.run_bundler_subprocess(
          bundler_version: bundler_version,
          function: "parsed_gemspec",
          options: options,
          args: {
            gemspec_name: file.name,
            lockfile_name: lockfile&.name,
            dir: Dir.pwd
          }
        )
      rescue SharedHelpers::HelperSubprocessFailed => e
        msg = e.error_class + " with message: " + e.message
        raise Dependabot::DependencyFileNotEvaluatable, msg
      end

      sig { returns(T.nilable(String)) }
      def base_directory
        dependency_files.first&.directory
      end

      sig { returns(T::Array[Dependabot::DependencyFile]) }
      def prepared_dependency_files
        @prepared_dependency_files ||= T.let(
          FilePreparer.new(dependency_files: dependency_files)
                              .prepared_dependency_files,
          T.nilable(T::Array[Dependabot::DependencyFile])
        )
      end

      sig { void }
      def write_temporary_dependency_files
        prepared_dependency_files.each do |file|
          path = file.name
          FileUtils.mkdir_p(Pathname.new(path).dirname)
          File.write(path, file.content)
        end

        File.write(T.must(lockfile).name, sanitized_lockfile_content) if lockfile
      end

      sig { override.void }
      def check_required_files
        file_names = dependency_files.map(&:name)

        return if file_names.any? do |name|
          name.end_with?(".gemspec") && !name.include?("/")
        end

        return if gemfile

        raise "A gemspec or Gemfile must be provided!"
      end

      sig { params(dependency_name: String).returns(T.nilable(T.any(Dependabot::Version, String, Gem::Version))) }
      def dependency_version(dependency_name)
        return unless lockfile

        spec = parsed_lockfile.specs.find { |s| s.name == dependency_name }

        # Not all files in the Gemfile will appear in the Gemfile.lock. For
        # instance, if a gem specifies `platform: [:windows]`, and the
        # Gemfile.lock is generated on a Linux machine, the gem will be not
        # appear in the lockfile.
        return unless spec

        # If the source is Git we're better off knowing the SHA-1 than the
        # version.
        return spec.source.revision if spec.source.instance_of?(::Bundler::Source::Git)

        spec.version
      end

      sig { returns(T.nilable(Dependabot::DependencyFile)) }
      def gemfile
        @gemfile ||= T.let(
          get_original_file("Gemfile") ||
                             get_original_file("gems.rb"),
          T.nilable(Dependabot::DependencyFile)
        )
      end

      sig { returns(T::Array[Dependabot::DependencyFile]) }
      def evaled_gemfiles
        dependency_files
          .reject { |f| f.name.end_with?(".gemspec") }
          .reject { |f| f.name.end_with?(".specification") }
          .reject { |f| f.name.end_with?(".lock") }
          .reject { |f| f.name == "Gemfile" }
          .reject { |f| f.name == "gems.rb" }
          .reject { |f| f.name == "gems.locked" }
          .reject(&:support_file?)
      end

      sig { returns(T.nilable(Dependabot::DependencyFile)) }
      def lockfile
        @lockfile ||= T.let(
          get_original_file("Gemfile.lock") ||
                              get_original_file("gems.locked"),
          T.nilable(Dependabot::DependencyFile)
        )
      end

      sig { returns(T.untyped) }
      def parsed_lockfile
        @parsed_lockfile = T.let(@parsed_lockfile, T.untyped)
        @parsed_lockfile ||= CachedLockfileParser.parse(sanitized_lockfile_content)
      end

      sig { returns(T::Array[String]) }
      def production_dep_names
        @production_dep_names ||= T.let(
          (gemfile_dependencies + gemspec_dependencies).dependencies
                                                               .select { |dep| production?(dep) }
                                                               .flat_map { |dep| expanded_dependency_names(dep) }
                                                               .uniq,
          T.nilable(T::Array[String])
        )
      end

      sig { params(dep: T.any(Dependabot::Dependency, Gem::Dependency)).returns(T::Array[String]) }
      def expanded_dependency_names(dep)
        spec = parsed_lockfile.specs.find { |s| s.name == dep.name }
        return [dep.name] unless spec

        [
          dep.name,
          *spec.dependencies.flat_map { |d| expanded_dependency_names(d) }
        ]
      end

      sig { params(dependency: Dependabot::Dependency).returns(T::Boolean) }
      def production?(dependency)
        groups = dependency.requirements
                           .flat_map { |r| r.fetch(:groups) }
                           .map(&:to_s)

        return true if groups.empty?
        return true if groups.include?("runtime")
        return true if groups.include?("default")

        groups.any? { |g| g.include?("prod") }
      end

      # TODO: Stop sanitizing the lockfile once we have bundler 2 installed
      sig { returns(String) }
      def sanitized_lockfile_content
        regex = FileUpdater::LockfileUpdater::LOCKFILE_ENDING
        T.must(T.must(lockfile).content).gsub(regex, "")
      end

      sig { returns(T::Array[Dependabot::DependencyFile]) }
      def gemspecs
        # Path gemspecs are excluded (they're supporting files)
        @gemspecs ||= T.let(
          prepared_dependency_files
                              .select { |file| file.name.end_with?(".gemspec") },
          T.nilable(T::Array[Dependabot::DependencyFile])
        )
      end

      sig { returns(T::Array[Dependabot::DependencyFile]) }
      def imported_ruby_files
        dependency_files
          .select { |f| f.name.end_with?(".rb") }
          .reject { |f| f.name == "gems.rb" }
      end

      sig { returns(String) }
      def bundler_raw_version
        @bundler_raw_version = T.let(@bundler_raw_version, T.nilable(String))
        return @bundler_raw_version if @bundler_raw_version

        package_manager = PackageManager.new(
          detected_version: bundler_version
        )

        # If the selected version is unsupported, an unsupported error will be raised,
        # so there's no need to attempt retrieving the raw version.
        return bundler_version if package_manager.unsupported?

        directory = base_directory
        # read raw version directly from the ecosystem environment
        bundler_raw_version = if directory
                                SharedHelpers.in_a_temporary_repo_directory(
                                  directory,
                                  repo_contents_path
                                ) do
                                  write_temporary_dependency_files
                                  NativeHelpers.run_bundler_subprocess(
                                    function: "bundler_raw_version",
                                    args: {},
                                    bundler_version: bundler_version,
                                    options: { timeout_per_operation_seconds: 10 }
                                  )
                                end
                              end
        @bundler_raw_version = bundler_raw_version || ::Bundler::VERSION
      end

      sig { returns(String) }
      def ruby_raw_version
        @ruby_raw_version = T.let(@ruby_raw_version, T.nilable(String))
        return @ruby_raw_version if @ruby_raw_version

        ruby_raw_version = SharedHelpers.in_a_temporary_repo_directory(
          T.must(base_directory),
          repo_contents_path
        ) do
          write_temporary_dependency_files
          NativeHelpers.run_bundler_subprocess(
            function: "ruby_raw_version",
            args: {},
            bundler_version: bundler_version,
            options: { timeout_per_operation_seconds: 10 }
          )
        end
        @ruby_raw_version = ruby_raw_version || RUBY_VERSION
      end

      sig { returns(String) }
      def bundler_version
        @bundler_version ||= T.let(Helpers.bundler_version(lockfile), T.nilable(String))
      end
    end
  end
end

Dependabot::FileParsers.register("bundler", Dependabot::Bundler::FileParser)
