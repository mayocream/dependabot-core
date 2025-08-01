# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "open3"
require "dependabot/dependency"
require "dependabot/python/requirement_parser"
require "dependabot/python/file_fetcher"
require "dependabot/python/file_parser"
require "dependabot/python/file_parser/python_requirement_parser"
require "dependabot/python/update_checker"
require "dependabot/python/file_updater/requirement_replacer"
require "dependabot/python/file_updater/setup_file_sanitizer"
require "dependabot/python/version"
require "dependabot/shared_helpers"
require "dependabot/python/language_version_manager"
require "dependabot/python/native_helpers"
require "dependabot/python/name_normaliser"
require "dependabot/python/authed_url_builder"

module Dependabot
  module Python
    class UpdateChecker
      # This class does version resolution for pip-compile. Its approach is:
      # - Unlock the dependency we're checking in the requirements.in file
      # - Run `pip-compile` and see what the result is
      class PipCompileVersionResolver # rubocop:disable Metrics/ClassLength
        extend T::Sig

        GIT_DEPENDENCY_UNREACHABLE_REGEX = T.let(/git clone --filter=blob:none --quiet (?<url>[^\s]+).* /, Regexp)
        GIT_REFERENCE_NOT_FOUND_REGEX = T.let(/Did not find branch or tag '(?<tag>[^\n"]+)'/m, Regexp)
        NATIVE_COMPILATION_ERROR = T.let(
          "pip._internal.exceptions.InstallationSubprocessError: Getting requirements to build wheel exited with 1",
          String
        )
        # See https://packaging.python.org/en/latest/tutorials/packaging-projects/#configuring-metadata
        PYTHON_PACKAGE_NAME_REGEX = T.let(/[A-Za-z0-9_\-]+/, Regexp)
        RESOLUTION_IMPOSSIBLE_ERROR = T.let("ResolutionImpossible", String)
        ERROR_REGEX = T.let(/(?<=ERROR\:\W).*$/, Regexp)

        sig { returns(Dependabot::Dependency) }
        attr_reader :dependency

        sig { returns(T::Array[Dependabot::DependencyFile]) }
        attr_reader :dependency_files

        sig { returns(T::Array[Dependabot::Credential]) }
        attr_reader :credentials

        sig { returns(T.nilable(String)) }
        attr_reader :repo_contents_path

        sig { returns(PipCompileErrorHandler) }
        attr_reader :error_handler

        sig do
          params(
            dependency: Dependabot::Dependency,
            dependency_files: T::Array[Dependabot::DependencyFile],
            credentials: T::Array[Dependabot::Credential],
            repo_contents_path: T.nilable(String)
          ).void
        end
        def initialize(dependency:, dependency_files:, credentials:, repo_contents_path:)
          @dependency = T.let(dependency, Dependabot::Dependency)
          @dependency_files = T.let(dependency_files, T::Array[Dependabot::DependencyFile])
          @credentials = T.let(credentials, T::Array[Dependabot::Credential])
          @repo_contents_path = T.let(repo_contents_path, T.nilable(String))
          @build_isolation = T.let(true, T::Boolean)
          @error_handler = T.let(PipCompileErrorHandler.new, PipCompileErrorHandler)
        end

        sig { params(requirement: T.nilable(String)).returns(T.nilable(Dependabot::Python::Version)) }
        def latest_resolvable_version(requirement: nil)
          @latest_resolvable_version_string ||= T.let(
            {},
            T.nilable(T::Hash[T.nilable(String), T.nilable(Dependabot::Python::Version)])
          )
          return @latest_resolvable_version_string[requirement] if @latest_resolvable_version_string.key?(requirement)

          version_string =
            fetch_latest_resolvable_version_string(requirement: requirement)

          @latest_resolvable_version_string[requirement] ||=
            version_string.nil? ? nil : Python::Version.new(version_string)
        end

        sig { params(version: Gem::Version).returns(T::Boolean) }
        def resolvable?(version:)
          @resolvable ||= T.let({}, T.nilable(T::Hash[Gem::Version, T::Boolean]))
          return T.must(@resolvable[version]) if @resolvable.key?(version)

          @resolvable[version] = if latest_resolvable_version(requirement: "==#{version}")
                                   true
                                 else
                                   false
                                 end
        end

        private

        sig { params(requirement: T.nilable(String)).returns(T.nilable(String)) }
        def fetch_latest_resolvable_version_string(requirement:)
          SharedHelpers.in_a_temporary_directory do
            SharedHelpers.with_git_configured(credentials: credentials) do
              write_temporary_dependency_files(updated_req: requirement)
              language_version_manager.install_required_python

              filenames_to_compile.each do |filename|
                return nil unless compile_file(filename)
              end

              # Remove any .python-version file before parsing the reqs
              FileUtils.remove_entry(".python-version", true)

              parse_updated_files
            end
          end
        end

        sig { params(filename: String).returns(T::Boolean) }
        def compile_file(filename)
          # Shell out to pip-compile.
          # This is slow, as pip-compile needs to do installs.
          options = pip_compile_options(filename)
          options_fingerprint = pip_compile_options_fingerprint(options)

          run_pip_compile_command(
            "pyenv exec pip-compile -v #{options} -P #{dependency.name} #{filename}",
            fingerprint: "pyenv exec pip-compile -v #{options_fingerprint} -P <dependency_name> <filename>"
          )

          return true if dependency.top_level?

          # Run pip-compile a second time for transient dependencies
          # to make sure we do not update dependencies that are
          # superfluous. pip-compile does not detect these when
          # updating a specific dependency with the -P option.
          # Running pip-compile a second time will automatically remove
          # superfluous dependencies. Dependabot then marks those with
          # update_not_possible.
          write_original_manifest_files
          run_pip_compile_command(
            "pyenv exec pip-compile #{options} #{filename}",
            fingerprint: "pyenv exec pip-compile #{options_fingerprint} <filename>"
          )

          true
        rescue SharedHelpers::HelperSubprocessFailed => e
          retry_count ||= 0
          retry_count += 1
          if compilation_error?(e) && retry_count <= 1
            @build_isolation = false
            retry
          end

          handle_pip_compile_errors(e.message)
          false
        end

        sig { params(error: Dependabot::SharedHelpers::HelperSubprocessFailed).returns(T::Boolean) }
        def compilation_error?(error)
          error.message.include?(NATIVE_COMPILATION_ERROR)
        end

        # rubocop:disable Metrics/AbcSize
        # rubocop:disable Metrics/PerceivedComplexity
        sig { params(message: String).returns(T.nilable(String)) }
        def handle_pip_compile_errors(message) # rubocop:disable Metrics/MethodLength
          if message.include?(RESOLUTION_IMPOSSIBLE_ERROR)
            check_original_requirements_resolvable
            # If the original requirements are resolvable but we get an
            # incompatibility error after unlocking then it's likely to be
            # due to problems with pip-compile's cascading resolution
            return nil
          end

          if message.include?("UnsupportedConstraint")
            # If there's an unsupported constraint, check if it existed
            # previously (and raise if it did)
            check_original_requirements_resolvable
          end

          if (message.include?('Command "python setup.py egg_info') ||
              message.include?(
                "exit status 1: python setup.py egg_info"
              )) &&
             check_original_requirements_resolvable
            # The latest version of the dependency we're updating is borked
            # (because it has an unevaluatable setup.py). Skip the update.
            return
          end

          if message.include?(RESOLUTION_IMPOSSIBLE_ERROR) &&
             !message.match?(/#{Regexp.quote(dependency.name)}/i)
            # Sometimes pip-tools gets confused and can't work around
            # sub-dependency incompatibilities. Ignore those cases.
            return nil
          end

          if message.match?(GIT_REFERENCE_NOT_FOUND_REGEX)
            tag = T.must(T.must(message.match(GIT_REFERENCE_NOT_FOUND_REGEX)).named_captures.fetch("tag"))
            constraints_section = T.must(message.split("Finding the best candidates:").first)
            egg_regex = /#{Regexp.escape(tag)}#egg=(#{PYTHON_PACKAGE_NAME_REGEX})/
            name_match = constraints_section.scan(egg_regex)

            # We can determine the name of the package from another part of the logger output if it has a unique tag
            if name_match.length == 1 && name_match.first.is_a?(Array)
              raise GitDependencyReferenceNotFound,
                    T.must(T.cast(T.must(name_match.first), T::Array[String]).first)
            end

            raise GitDependencyReferenceNotFound, "(unknown package at #{tag})"
          end

          if message.match?(GIT_DEPENDENCY_UNREACHABLE_REGEX)
            url = T.must(message.match(GIT_DEPENDENCY_UNREACHABLE_REGEX))
                   .named_captures.fetch("url")
            raise GitDependenciesNotReachable, T.must(url)
          end

          raise Dependabot::OutOfDisk if message.end_with?("[Errno 28] No space left on device")

          raise Dependabot::OutOfMemory if message.end_with?("MemoryError")

          error_handler.handle_pipcompile_error(message)

          raise
        end
        # rubocop:enable Metrics/AbcSize
        # rubocop:enable Metrics/PerceivedComplexity

        # Needed because pip-compile's resolver isn't perfect.
        # Note: We raise errors from this method, rather than returning a
        # boolean, so that all deps for this repo will raise identical
        # errors when failing to update
        sig { returns(T::Boolean) }
        def check_original_requirements_resolvable
          SharedHelpers.in_a_temporary_directory do
            SharedHelpers.with_git_configured(credentials: credentials) do
              write_temporary_dependency_files(update_requirement: false)

              filenames_to_compile.each do |filename|
                options = pip_compile_options(filename)
                options_fingerprint = pip_compile_options_fingerprint(options)

                run_pip_compile_command(
                  "pyenv exec pip-compile #{options} #{filename}",
                  fingerprint: "pyenv exec pip-compile #{options_fingerprint} <filename>"
                )
              end

              true
            rescue SharedHelpers::HelperSubprocessFailed => e
              # Pick the error message that includes resolvability errors, this might be the cause from
              # handle_pip_compile_errors (it's unclear if we should always pick the cause here)
              error_message = [e.message, e.cause&.message].compact.find do |msg|
                msg.include?(RESOLUTION_IMPOSSIBLE_ERROR)
              end

              cleaned_message = clean_error_message(error_message || "")
              raise if cleaned_message.empty?

              raise DependencyFileNotResolvable, cleaned_message
            end
          end
        end

        sig { params(command: String, fingerprint: String, env: T::Hash[String, String]).void }
        def run_command(command, fingerprint:, env: python_env)
          SharedHelpers.run_shell_command(command, env: env, fingerprint: fingerprint, stderr_to_stdout: true)
        end

        sig { params(options: String).returns(String) }
        def pip_compile_options_fingerprint(options)
          options.sub(
            /--output-file=\S+/, "--output-file=<output_file>"
          ).sub(
            /--index-url=\S+/, "--index-url=<index_url>"
          ).sub(
            /--extra-index-url=\S+/, "--extra-index-url=<extra_index_url>"
          )
        end

        sig { params(filename: String).returns(String) }
        def pip_compile_options(filename)
          options = @build_isolation ? ["--build-isolation"] : ["--no-build-isolation"]
          options += pip_compile_index_options
          # TODO: Stop explicitly specifying `allow-unsafe` once it becomes the default:
          # https://github.com/jazzband/pip-tools/issues/989#issuecomment-1661254701
          options += ["--allow-unsafe"]

          if (requirements_file = compiled_file_for_filename(filename))
            options << "--output-file=#{requirements_file.name}"
          end

          options.join(" ")
        end

        sig { returns(T::Array[String]) }
        def pip_compile_index_options
          credentials
            .select { |cred| cred["type"] == "python_index" }
            .map do |cred|
              authed_url = AuthedUrlBuilder.authed_url(credential: cred)

              if cred.replaces_base?
                "--index-url=#{authed_url}"
              else
                "--extra-index-url=#{authed_url}"
              end
            end
        end

        sig { params(command: String, fingerprint: String).void }
        def run_pip_compile_command(command, fingerprint:)
          run_command(
            "pyenv local #{language_version_manager.python_major_minor}",
            fingerprint: "pyenv local <python_major_minor>"
          )

          run_command(command, fingerprint: fingerprint)
        end

        sig { returns(T::Hash[String, String]) }
        def python_env
          env = {}

          # Handle Apache Airflow 1.10.x installs
          if dependency_files.any? { |f| T.must(f.content).include?("apache-airflow") }
            if dependency_files.any? { |f| T.must(f.content).include?("unidecode") }
              env["AIRFLOW_GPL_UNIDECODE"] = "yes"
            else
              env["SLUGIFY_USES_TEXT_UNIDECODE"] = "yes"
            end
          end

          env
        end

        sig do
          params(updated_req: T.nilable(String), update_requirement: T::Boolean)
            .returns(T::Array[Dependabot::DependencyFile])
        end
        def write_temporary_dependency_files(updated_req: nil, update_requirement: true)
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            updated_content =
              if update_requirement then update_req_file(file, updated_req)
              else
                file.content
              end
            File.write(path, updated_content)
          end

          # Overwrite the .python-version with updated content
          File.write(".python-version", language_version_manager.python_major_minor)

          setup_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, sanitized_setup_file_content(file))
          end

          setup_cfg_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, "[metadata]\nname = sanitized-package\n")
          end
        end

        sig { void }
        def write_original_manifest_files
          pip_compile_files.each do |file|
            FileUtils.mkdir_p(Pathname.new(file.name).dirname)
            File.write(file.name, file.content)
          end
        end

        sig { params(file: Dependabot::DependencyFile).returns(String) }
        def sanitized_setup_file_content(file)
          @sanitized_setup_file_content ||= T.let({}, T.nilable(T::Hash[String, String]))
          return T.must(@sanitized_setup_file_content[file.name]) if @sanitized_setup_file_content[file.name]

          @sanitized_setup_file_content[file.name] =
            Python::FileUpdater::SetupFileSanitizer
            .new(setup_file: file, setup_cfg: setup_cfg(file))
            .sanitized_content
        end

        sig { params(file: Dependabot::DependencyFile).returns(T.nilable(Dependabot::DependencyFile)) }
        def setup_cfg(file)
          dependency_files.find do |f|
            f.name == file.name.sub(/\.py$/, ".cfg")
          end
        end

        sig { params(file: Dependabot::DependencyFile, updated_req: T.nilable(String)).returns(String) }
        def update_req_file(file, updated_req)
          return T.must(file.content) unless file.name.end_with?(".in")

          req = dependency.requirements.find { |r| r[:file] == file.name }

          return T.must(file.content) + "\n#{dependency.name} #{updated_req}" unless req&.fetch(:requirement)

          Python::FileUpdater::RequirementReplacer.new(
            content: T.must(file.content),
            dependency_name: dependency.name,
            old_requirement: req[:requirement],
            new_requirement: updated_req
          ).updated_content
        end

        sig { params(name: String).returns(String) }
        def normalise(name)
          NameNormaliser.normalise(name)
        end

        sig { params(message: String).returns(String) }
        def clean_error_message(message)
          T.must(T.cast(message.scan(ERROR_REGEX), T::Array[String]).last)
        end

        sig { returns(T::Array[String]) }
        def filenames_to_compile
          files_from_reqs =
            dependency.requirements
                      .map { |r| r[:file] }
                      .select { |fn| fn.end_with?(".in") }

          files_from_compiled_files =
            pip_compile_files.map(&:name).select do |fn|
              compiled_file = compiled_file_for_filename(fn)
              compiled_file_includes_dependency?(compiled_file)
            end

          filenames = [*files_from_reqs, *files_from_compiled_files].uniq

          order_filenames_for_compilation(filenames)
        end

        sig { params(filename: String).returns(T.nilable(Dependabot::DependencyFile)) }
        def compiled_file_for_filename(filename)
          compiled_file =
            compiled_files
            .find { |f| T.must(f.content).match?(output_file_regex(filename)) }

          compiled_file ||=
            compiled_files
            .find { |f| f.name == filename.gsub(/\.in$/, ".txt") }

          compiled_file
        end

        sig { params(filename: String).returns(String) }
        def output_file_regex(filename)
          "--output-file[=\s]+.*\s#{Regexp.escape(filename)}\s*$"
        end

        sig { params(compiled_file: T.nilable(Dependabot::DependencyFile)).returns(T::Boolean) }
        def compiled_file_includes_dependency?(compiled_file)
          return false unless compiled_file

          regex = RequirementParser::INSTALL_REQ_WITH_REQUIREMENT

          matches = []
          T.must(compiled_file.content).scan(regex) { matches << Regexp.last_match }
          matches.any? { |m| normalise(m[:name]) == dependency.name }
        end

        # If the files we need to update require one another then we need to
        # update them in the right order
        sig { params(filenames: T::Array[String]).returns(T::Array[String]) }
        def order_filenames_for_compilation(filenames)
          ordered_filenames = T.let([], T::Array[String])

          while (remaining_filenames = filenames - ordered_filenames).any?
            ordered_filenames +=
              remaining_filenames
              .reject do |fn|
                unupdated_reqs = T.must(requirement_map[fn]) - ordered_filenames
                unupdated_reqs.intersect?(filenames)
              end
          end

          ordered_filenames
        end

        sig { returns(T::Hash[String, T::Array[String]]) }
        def requirement_map
          child_req_regex = Python::FileFetcher::CHILD_REQUIREMENT_REGEX
          @requirement_map ||= T.let(
            pip_compile_files.each_with_object({}) do |file, req_map|
              paths = T.must(file.content).scan(child_req_regex).flatten
              current_dir = File.dirname(file.name)

              req_map[file.name] =
                paths.map do |path|
                  path = File.join(current_dir, path) if current_dir != "."
                  path = Pathname.new(path).cleanpath.to_path
                  path = path.gsub(/\.txt$/, ".in")
                  next if path == file.name

                  path
                end.uniq.compact
            end,
            T.nilable(T::Hash[String, T::Array[String]])
          )
        end

        sig { returns(T.nilable(String)) }
        def parse_updated_files
          updated_files =
            dependency_files.map do |file|
              next file if file.name == ".python-version"

              updated_file = file.dup
              updated_file.content = File.read(file.name)
              updated_file
            end

          Python::FileParser.new(
            dependency_files: updated_files,
            source: nil,
            credentials: credentials
          ).parse.find { |d| d.name == dependency.name }&.version
        end

        sig { returns(Dependabot::Python::FileParser::PythonRequirementParser) }
        def python_requirement_parser
          @python_requirement_parser ||= T.let(
            FileParser::PythonRequirementParser.new(
              dependency_files: dependency_files
            ), T.nilable(FileParser::PythonRequirementParser)
          )
        end

        sig { returns(Dependabot::Python::LanguageVersionManager) }
        def language_version_manager
          @language_version_manager ||= T.let(
            LanguageVersionManager.new(
              python_requirement_parser: python_requirement_parser
            ), T.nilable(LanguageVersionManager)
          )
        end

        sig { returns(T::Array[Dependabot::DependencyFile]) }
        def setup_files
          dependency_files.select { |f| f.name.end_with?("setup.py") }
        end

        sig { returns(T::Array[Dependabot::DependencyFile]) }
        def pip_compile_files
          dependency_files.select { |f| f.name.end_with?(".in") }
        end

        sig { returns(T::Array[Dependabot::DependencyFile]) }
        def compiled_files
          dependency_files.select { |f| f.name.end_with?(".txt") }
        end

        sig { returns(T::Array[Dependabot::DependencyFile]) }
        def setup_cfg_files
          dependency_files.select { |f| f.name.end_with?("setup.cfg") }
        end
      end
    end

    class PipCompileErrorHandler
      extend T::Sig

      SUBPROCESS_ERROR = T.let(/subprocess-exited-with-error/, Regexp)

      INSTALLATION_ERROR = T.let(/InstallationError/, Regexp)

      INSTALLATION_SUBPROCESS_ERROR = T.let(/InstallationSubprocessError/, Regexp)

      HASH_MISMATCH = T.let(/HashMismatch/, Regexp)

      sig { params(error: String).void }
      def handle_pipcompile_error(error)
        return unless error.match?(SUBPROCESS_ERROR) || error.match?(INSTALLATION_ERROR) ||
                      error.match?(INSTALLATION_SUBPROCESS_ERROR) || error.match?(HASH_MISMATCH)

        raise DependencyFileNotResolvable, "Error resolving dependency"
      end
    end
  end
end
