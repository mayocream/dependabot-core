# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"
require "toml-rb"

require "dependabot/file_fetchers"
require "dependabot/file_fetchers/base"
require "dependabot/cargo/file_parser"

# Docs on Cargo workspaces:
# https://doc.rust-lang.org/cargo/reference/manifest.html#the-workspace-section
module Dependabot
  module Cargo
    class FileFetcher < Dependabot::FileFetchers::Base
      extend T::Sig
      extend T::Helpers

      sig { override.params(filenames: T::Array[String]).returns(T::Boolean) }
      def self.required_files_in?(filenames)
        filenames.include?("Cargo.toml")
      end

      sig { override.returns(String) }
      def self.required_files_message
        "Repo must contain a Cargo.toml."
      end

      sig { override.returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def ecosystem_versions
        channel = if rust_toolchain
                    TomlRB.parse(T.must(rust_toolchain).content).fetch("toolchain", nil)&.fetch("channel", nil)
                  else
                    "default"
                  end

        {
          package_managers: {
            "cargo" => channel
          }
        }
      rescue TomlRB::ParseError
        raise Dependabot::DependencyFileNotParseable.new(
          T.must(rust_toolchain).path,
          "only rust-toolchain files formatted as TOML are supported, the non-TOML format was deprecated by Rust"
        )
      end

      sig { override.returns(T::Array[DependencyFile]) }
      def fetch_files
        fetched_files = T.let([], T::Array[DependencyFile])
        fetched_files << cargo_toml
        fetched_files << T.must(cargo_lock) if cargo_lock
        fetched_files << T.must(cargo_config) if cargo_config
        fetched_files << T.must(rust_toolchain) if rust_toolchain
        fetched_files += fetch_path_dependency_and_workspace_files
        fetched_files.uniq
      end

      private

      sig do
        params(files: T.nilable(T::Array[Dependabot::DependencyFile])).returns(T::Array[Dependabot::DependencyFile])
      end
      def fetch_path_dependency_and_workspace_files(files = nil)
        fetched_files = files || [cargo_toml]

        fetched_files += path_dependency_files(fetched_files)
        fetched_files += fetched_files.flat_map { |f| workspace_files(f) }

        updated_files = fetched_files.reject(&:support_file?).uniq
        updated_files +=
          fetched_files.uniq
                       .reject { |f| updated_files.map(&:name).include?(f.name) }

        return updated_files if updated_files == files

        fetch_path_dependency_and_workspace_files(updated_files)
      end

      sig { params(cargo_toml: Dependabot::DependencyFile).returns(T::Array[Dependabot::DependencyFile]) }
      def workspace_files(cargo_toml)
        @workspace_files ||= T.let({}, T.nilable(T::Hash[String, T::Array[Dependabot::DependencyFile]]))
        @workspace_files[cargo_toml.name] ||=
          fetch_workspace_files(
            file: cargo_toml,
            previously_fetched_files: []
          )
      end

      sig { params(fetched_files: T::Array[Dependabot::DependencyFile]).returns(T::Array[Dependabot::DependencyFile]) }
      def path_dependency_files(fetched_files)
        @path_dependency_files ||= T.let({}, T.nilable(T::Hash[String, T::Array[Dependabot::DependencyFile]]))
        fetched_path_dependency_files = T.let([], T::Array[Dependabot::DependencyFile])
        fetched_files.each do |file|
          @path_dependency_files[file.name] ||=
            fetch_path_dependency_files(
              file: file,
              previously_fetched_files: fetched_files +
                                        fetched_path_dependency_files
            )

          fetched_path_dependency_files += T.must(@path_dependency_files[file.name])
        end

        fetched_path_dependency_files
      end

      sig do
        params(
          file: Dependabot::DependencyFile,
          previously_fetched_files: T::Array[Dependabot::DependencyFile]
        )
          .returns(T::Array[Dependabot::DependencyFile])
      end
      def fetch_workspace_files(file:, previously_fetched_files:)
        current_dir = file.name.rpartition("/").first
        current_dir = nil if current_dir == ""

        files = workspace_dependency_paths_from_file(file).flat_map do |path|
          path = File.join(current_dir, path) unless current_dir.nil?
          path = Pathname.new(path).cleanpath.to_path

          next if previously_fetched_files.map(&:name).include?(path)
          next if file.name == path

          fetched_file = fetch_file_from_host(path, fetch_submodules: true)
          previously_fetched_files << fetched_file
          grandchild_requirement_files =
            fetch_workspace_files(
              file: fetched_file,
              previously_fetched_files: previously_fetched_files
            )
          [fetched_file, *grandchild_requirement_files]
        end.compact

        files.each { |f| f.support_file = file != cargo_toml }
        files
      end

      # rubocop:disable Metrics/PerceivedComplexity
      sig do
        params(
          file: Dependabot::DependencyFile,
          previously_fetched_files: T::Array[Dependabot::DependencyFile]
        )
          .returns(T::Array[Dependabot::DependencyFile])
      end
      def fetch_path_dependency_files(file:, previously_fetched_files:)
        current_dir = file.name.rpartition("/").first
        current_dir = nil if current_dir == ""
        unfetchable_required_path_deps = []

        path_dependency_files ||=
          path_dependency_paths_from_file(file).flat_map do |path|
            path = File.join(current_dir, path) unless current_dir.nil?
            path = Pathname.new(path).cleanpath.to_path

            next if previously_fetched_files.map(&:name).include?(path)
            next if file.name == path

            fetched_file = fetch_file_from_host(path, fetch_submodules: true)
                           .tap { |f| f.support_file = true }
            previously_fetched_files << fetched_file
            grandchild_requirement_files =
              fetch_path_dependency_files(
                file: fetched_file,
                previously_fetched_files: previously_fetched_files
              )

            # If this path dependency file is a workspace member that inherits from
            # its root workspace, we search for the root to include it so Cargo can
            # resolve the path dependency file manifest properly.
            root = find_workspace_root(fetched_file) if workspace_member?(parsed_file(fetched_file))

            [fetched_file, *grandchild_requirement_files, root]
          rescue Dependabot::DependencyFileNotFound
            next unless required_path?(file, path)

            unfetchable_required_path_deps << path
          end.compact

        return path_dependency_files if unfetchable_required_path_deps.none?

        raise Dependabot::PathDependenciesNotReachable,
              unfetchable_required_path_deps
      end

      sig { params(dependencies: T::Hash[T.untyped, T.untyped]).returns(T::Array[String]) }
      def collect_path_dependencies_paths(dependencies)
        paths = []
        dependencies.each do |_, details|
          next unless details.is_a?(Hash) && details["path"]

          paths << File.join(details["path"], "Cargo.toml").delete_prefix("/")
        end
        paths
      end

      # rubocop:enable Metrics/PerceivedComplexity
      sig { params(file: Dependabot::DependencyFile).returns(T::Array[String]) }
      def path_dependency_paths_from_file(file)
        paths = T.let([], T::Array[String])

        workspace = parsed_file(file).fetch("workspace", {})
        Cargo::FileParser::DEPENDENCY_TYPES.each do |type|
          # Paths specified in dependency declaration
          paths += collect_path_dependencies_paths(parsed_file(file).fetch(type, {}))
          # Paths specified as workspace dependencies in workspace root
          paths += collect_path_dependencies_paths(workspace.fetch(type, {}))
        end

        # Paths specified for target-specific dependencies
        parsed_file(file).fetch("target", {}).each do |_, t_details|
          Cargo::FileParser::DEPENDENCY_TYPES.each do |type|
            paths += collect_path_dependencies_paths(t_details.fetch(type, {}))
          end
        end

        paths += replacement_path_dependency_paths_from_file(file)
        paths
      end

      sig { params(file: Dependabot::DependencyFile).returns(T::Array[String]) }
      def replacement_path_dependency_paths_from_file(file)
        paths = []

        # Paths specified as replacements
        parsed_file(file).fetch("replace", {}).each do |_, details|
          next unless details.is_a?(Hash)
          next unless details["path"]

          paths << File.join(details["path"], "Cargo.toml")
        end

        # Paths specified as patches
        parsed_file(file).fetch("patch", {}).each do |_, details|
          next unless details.is_a?(Hash)

          details.each do |_, dep_details|
            next unless dep_details.is_a?(Hash)
            next unless dep_details["path"]

            paths << File.join(dep_details["path"], "Cargo.toml")
          end
        end

        paths
      end

      # See if this Cargo manifest inherits any property from a workspace
      # (e.g. edition = { workspace = true }).
      sig { params(hash: T::Hash[T.untyped, T.untyped]).returns(T::Boolean) }
      def workspace_member?(hash)
        hash.each do |key, value|
          if key == "workspace" && value == true
            return true
          elsif value.is_a?(Hash)
            return workspace_member?(value)
          end
        end
        false
      end

      # Find workspace root of this workspace member, first via package.workspace
      # manifest key if present, otherwise resort to searching parent directories
      # up till the repository root.
      sig do
        params(workspace_member: Dependabot::DependencyFile).returns(T.nilable(Dependabot::DependencyFile))
      end
      def find_workspace_root(workspace_member)
        current_dir = workspace_member.name.rpartition("/").first

        workspace_root_dir = parsed_file(workspace_member).dig("package", "workspace")
        unless workspace_root_dir.nil?
          workspace_root = fetch_file_from_host(
            File.join(current_dir, workspace_root_dir, "Cargo.toml"),
            fetch_submodules: true
          )
          return workspace_root if parsed_file(workspace_root)["workspace"]

          # To avoid accidentally breaking backward compatibility, we don't throw errors
          return nil
        end

        parent_dirs = current_dir.scan("/").length
        while parent_dirs >= 0
          current_dir = File.join(current_dir, "..")
          begin
            parent_manifest = fetch_file_from_host(
              File.join(current_dir, "Cargo.toml"),
              fetch_submodules: true
            )
            return parent_manifest if parsed_file(parent_manifest)["workspace"]
          rescue Dependabot::DependencyFileNotFound
            # Cargo.toml not found in this parent, keep searching up
          end
          parent_dirs -= 1
        end

        # To avoid accidentally breaking backward compatibility, we don't throw errors
        nil
      end

      sig { params(file: Dependabot::DependencyFile).returns(T::Array[String]) }
      def workspace_dependency_paths_from_file(file)
        if parsed_file(file)["workspace"] &&
           !parsed_file(file)["workspace"].key?("members")
          return path_dependency_paths_from_file(file)
        end

        workspace_paths = parsed_file(file).dig("workspace", "members")
        return [] unless workspace_paths&.any?

        # Expand any workspace paths that specify a `*`
        workspace_paths = workspace_paths.flat_map do |path|
          path.include?("*") ? expand_workspaces(path) : [path]
        end

        # Excluded paths, to be subtracted for the workspaces array
        excluded_paths =
          (parsed_file(file).dig("workspace", "excluded_paths") || []) +
          (parsed_file(file).dig("workspace", "exclude") || [])

        (workspace_paths - excluded_paths).map do |path|
          File.join(path, "Cargo.toml")
        end
      end

      # Check whether a path is required or not. It will not be required if
      # an alternative source (i.e., a git source) is also specified
      # rubocop:disable Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/PerceivedComplexity
      # rubocop:disable Metrics/AbcSize
      sig { params(file: Dependabot::DependencyFile, path: String).returns(T::Boolean) }
      def required_path?(file, path)
        # Paths specified in dependency declaration
        Cargo::FileParser::DEPENDENCY_TYPES.each do |type|
          parsed_file(file).fetch(type, {}).each do |_, details|
            next unless details.is_a?(Hash)
            next unless details["path"]
            next unless path == File.join(details["path"], "Cargo.toml")

            return true if details["git"].nil?
          end
        end

        # Paths specified for target-specific dependencies
        parsed_file(file).fetch("target", {}).each do |_, t_details|
          Cargo::FileParser::DEPENDENCY_TYPES.each do |type|
            t_details.fetch(type, {}).each do |_, details|
              next unless details.is_a?(Hash)
              next unless details["path"]
              next unless path == File.join(details["path"], "Cargo.toml")

              return true if details["git"].nil?
            end
          end
        end

        # Paths specified for workspace-wide dependencies
        workspace = parsed_file(file).fetch("workspace", {})
        workspace.fetch("dependencies", {}).each do |_, details|
          next unless details.is_a?(Hash)
          next unless details["path"]
          next unless path == File.join(details["path"], "Cargo.toml")

          return true if details["git"].nil?
        end

        # Paths specified as replacements
        parsed_file(file).fetch("replace", {}).each do |_, details|
          next unless details.is_a?(Hash)
          next unless details["path"]
          next unless path == File.join(details["path"], "Cargo.toml")

          return true if details["git"].nil?
        end

        false
      end
      # rubocop:enable Metrics/AbcSize
      # rubocop:enable Metrics/PerceivedComplexity
      # rubocop:enable Metrics/CyclomaticComplexity

      sig { params(path: String).returns(T::Array[String]) }
      def expand_workspaces(path)
        path = Pathname.new(path).cleanpath.to_path
        dir = directory.gsub(%r{(^/|/$)}, "")
        unglobbed_path = T.must(path.split("*").first).gsub(%r{(?<=/)[^/]*$}, "")

        repo_contents(dir: unglobbed_path, raise_errors: false)
          .select { |file| file.type == "dir" }
          .map { |f| f.path.gsub(%r{^/?#{Regexp.escape(dir)}/?}, "") }
          .select { |filename| File.fnmatch?(path, filename) }
      end

      sig { params(file: Dependabot::DependencyFile).returns(T::Hash[T.untyped, T.untyped]) }
      def parsed_file(file)
        TomlRB.parse(file.content)
      rescue TomlRB::ParseError, TomlRB::ValueOverwriteError
        raise Dependabot::DependencyFileNotParseable, file.path
      end

      sig { returns(Dependabot::DependencyFile) }
      def cargo_toml
        @cargo_toml ||= T.let(fetch_file_from_host("Cargo.toml"), T.nilable(Dependabot::DependencyFile))
      end

      sig { returns(T.nilable(Dependabot::DependencyFile)) }
      def cargo_lock
        @cargo_lock ||= T.let(
          fetch_file_if_present("Cargo.lock"),
          T.nilable(Dependabot::DependencyFile)
        )
      end

      sig { returns(T.nilable(Dependabot::DependencyFile)) }
      def cargo_config
        return @cargo_config if defined?(@cargo_config)

        @cargo_config = fetch_support_file(".cargo/config.toml")

        @cargo_config ||= T.let(
          fetch_support_file(".cargo/config")&.tap { |f| f.name = ".cargo/config.toml" },
          T.nilable(Dependabot::DependencyFile)
        )
      end

      sig { returns(T.nilable(Dependabot::DependencyFile)) }
      def rust_toolchain
        return @rust_toolchain if defined?(@rust_toolchain)

        @rust_toolchain = fetch_support_file("rust-toolchain")

        # Per https://rust-lang.github.io/rustup/overrides.html the file can
        # have a `.toml` extension, but the non-extension version is preferred.
        # Renaming here to simplify finding it later in the code.
        @rust_toolchain ||= T.let(
          fetch_support_file("rust-toolchain.toml")&.tap { |f| f.name = "rust-toolchain" },
          T.nilable(Dependabot::DependencyFile)
        )
      end
    end
  end
end

Dependabot::FileFetchers.register("cargo", Dependabot::Cargo::FileFetcher)
