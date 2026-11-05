require "digest"
require "fileutils"
require "net/http"
require "pathname"
require "securerandom"
require "uri"

module Sonance
  class ModelStore
    DOWNLOAD_HOST = "essentia.upf.edu".freeze

    def self.validate_download_uri!(url)
      uri = url.is_a?(URI) ? url : URI(url)
      raise BackendError, "model downloads require HTTPS: #{uri}" unless uri.is_a?(URI::HTTPS)
      return uri if uri.host == DOWNLOAD_HOST

      raise BackendError, "model download host #{uri.host.inspect} is not allowed"
    rescue URI::InvalidURIError
      raise BackendError, "model download URL is invalid: #{url}"
    end

    # Pathname operations bind an inode at verify time, not backend reopen time; sound only while the
    # models root is not attacker-writable: https://github.com/Lhosb/sonance/issues/2
    # rubocop:disable-next Metrics/ClassLength
    class Files
      Temporary = Data.define(:path, :file, :device, :inode)

      CREATE_FLAGS = File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW
      READ_FLAGS = File::RDONLY | File::NOFOLLOW
      READ_SIZE = 16 * 1024
      TEMP_ATTEMPTS = 10

      def initialize(root)
        @configured_root = Pathname(root).expand_path
        @root = nil
        @root_identity = nil
      end

      def ensure_directory!
        FileUtils.mkdir_p(configured_root, mode: 0o700)
        detect_root_misconfiguration!
      end

      def digest(filename)
        path = path_for(filename)
        File.open(path, READ_FLAGS) do |file|
          raise ConfigurationError, "model path must be a regular file: #{path}" unless file.stat.file?

          digest_io(file)
        end
      rescue Errno::ELOOP
        raise ConfigurationError, "model path must not be a symlink: #{path}"
      rescue Errno::ENOENT
        raise ConfigurationError, "missing model: #{path}"
      end

      def create_temporary(filename)
        ensure_directory!

        TEMP_ATTEMPTS.times do
          path = misconfiguration_checked_root.join(".#{filename}.#{SecureRandom.hex(16)}.download")
          file = File.new(path, CREATE_FLAGS, 0o600)
          stat = file.stat
          return Temporary.new(path:, file:, device: stat.dev, inode: stat.ino)
        rescue Errno::EEXIST, Errno::ELOOP
          next
        end

        raise BackendError, "unable to create a secure temporary model file"
      end

      def digest_io(file)
        file.flush
        file.rewind
        digest = Digest::SHA256.new
        while (chunk = file.read(READ_SIZE))
          digest.update(chunk)
        end
        digest.hexdigest
      end

      def replace(temporary, filename)
        stat = temporary.path.lstat
        unless stat.file? && !stat.symlink? &&
               stat.dev == temporary.device && stat.ino == temporary.inode
          raise ConfigurationError, "temporary model file was replaced before installation"
        end

        File.rename(temporary.path, path_for(filename))
      rescue Errno::ENOENT
        raise ConfigurationError, "temporary model file was replaced before installation"
      end

      def delete(temporary)
        return unless temporary
        return unless temporary.path.exist? || temporary.path.symlink?

        temporary.path.delete
      end

      private

      attr_reader :configured_root, :root, :root_identity

      def path_for(filename)
        directory = misconfiguration_checked_root
        path = directory.join(filename).expand_path
        return path if path.dirname == directory && path.basename.to_s == filename

        raise ConfigurationError, "model path escapes models directory: #{filename}"
      end

      def misconfiguration_checked_root
        detect_root_misconfiguration!
        root
      end

      def detect_root_misconfiguration!
        stat = configured_root.lstat
        # Keep type before permissions: symlink modes differ between Linux CI and macOS,
        # so reordering can change the error on CI without failing locally.
        detect_root_type_misconfiguration!(stat)
        detect_root_permission_misconfiguration!(stat)

        canonical = configured_root.realpath
        identity = [stat.dev, stat.ino]
        detect_root_replacement!(canonical, identity)

        @root = canonical
        @root_identity = identity
      rescue Errno::ENOENT
        raise ConfigurationError, "missing models directory: #{configured_root}"
      end

      def detect_root_type_misconfiguration!(stat)
        if stat.symlink?
          raise ConfigurationError, "models directory misconfiguration: path is a symlink: #{configured_root}"
        end
        return if stat.directory?

        raise ConfigurationError, "models directory misconfiguration: path is not a directory: #{configured_root}"
      end

      def detect_root_permission_misconfiguration!(stat)
        unless stat.uid == Process.euid
          raise ConfigurationError,
                "models directory misconfiguration: must be owned by the current user: #{configured_root}"
        end
        return if stat.mode.nobits?(0o022)

        raise ConfigurationError,
              "models directory misconfiguration: must not be group- or world-writable: #{configured_root}"
      end

      def detect_root_replacement!(canonical, identity)
        return unless root_identity
        return if root_identity == identity && root == canonical

        raise ConfigurationError, "models directory changed during use: #{configured_root}"
      end
    end

    class Downloader
      REDIRECT_LIMIT = 5

      def download(url, output)
        response = request(URI(url), REDIRECT_LIMIT)
        unless response.is_a?(Net::HTTPSuccess)
          raise BackendError, "model download failed with HTTP #{response.code}: #{url}"
        end

        output.write(response.body)
      end

      private

      def request(uri, redirects_remaining)
        uri = ModelStore.validate_download_uri!(uri)

        response = Net::HTTP.get_response(uri)
        return response unless response.is_a?(Net::HTTPRedirection)
        raise BackendError, "too many redirects downloading #{uri}" if redirects_remaining.zero?

        location = response["location"]
        raise BackendError, "redirect omitted location downloading #{uri}" unless location

        request(URI.join(uri, location), redirects_remaining - 1)
      end
    end

    def initialize(models_dir, registry: Registry.default, downloader: Downloader.new)
      @model_files = Files.new(models_dir)
      @registry = registry
      @downloader = downloader
    end

    def verify!(filenames:)
      filenames.each { |filename| verify_model!(model_for(filename)) }
      true
    end

    def fetch!
      model_files.ensure_directory!
      registry.models.each { |model| fetch_model!(model) }
      verify!(filenames: registry.models.map(&:filename))
    end

    private

    attr_reader :model_files, :registry, :downloader

    def model_for(filename)
      registry.models.find { |model| model.filename == filename } ||
        raise(ConfigurationError, "unknown model: #{filename}")
    end

    def verify_model!(model)
      return if model_files.digest(model.filename) == model.sha256

      raise ConfigurationError, "model digest mismatch: #{model.filename}"
    end

    def fetch_model!(model)
      source_uri = self.class.validate_download_uri!(model.source_url)
      temporary = model_files.create_temporary(model.filename)
      output = temporary.file

      downloader.download(source_uri.to_s, output)
      unless model_files.digest_io(output) == model.sha256
        raise ConfigurationError, "downloaded model digest mismatch: #{model.filename}"
      end

      model_files.replace(temporary, model.filename)
    ensure
      output&.close
      model_files.delete(temporary)
    end
  end
end
