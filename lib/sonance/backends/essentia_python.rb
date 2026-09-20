require "json"
require "open3"
require "pathname"
require "tempfile"
require "timeout"

module Sonance
  module Backends
    # rubocop:disable Metrics/ClassLength
    class EssentiaPython
      STARTUP_GRACE = 10
      PLAN_ARGUMENT_LIMIT = 64 * 1024
      # Ceiling on how much backend stderr may become an exception message. A single
      # three-file run was measured emitting 24,948 bytes of Essentia warning chatter, all of
      # which became the raised message verbatim. Head and tail are both kept because the
      # cause is usually in one or the other -- the configuration error at the top or the
      # traceback at the bottom -- and the middle is repeated warning lines.
      STDERR_MESSAGE_BYTES = 4 * 1024
      STDERR_MESSAGE_HEAD = STDERR_MESSAGE_BYTES / 2
      SCRIPT_PATH = Pathname(__dir__).join("../../../python/sonance_extract.py").expand_path

      class CommandTimeout < StandardError; end
      class CommandLaunchError < StandardError; end

      class CommandRunner
        # Ceiling on each captured stream. Both are held whole in memory before any protocol
        # parsing, so an unbounded backend drives the parent to exhaustion
        # (https://github.com/Lhosb/sonance/issues/6).
        #
        # This ceiling CAN be reached by legitimate output, because `analyze_all` funnels a whole
        # batch through one subprocess and one pair of streams, so both grow linearly with batch
        # size and nothing caps batch size first. Measured against real Essentia at 32 MiB:
        #
        #   stdout  ~4.5 KiB per path   (a full-precision nine-descriptor NDJSON line measured
        #                                4,513 B, dominated by the 200-float embedding at 3,830 B)
        #                                -> binds at roughly 7,400 paths
        #   stderr  scales with AUDIO DURATION, not just path count, at roughly 4.6 KiB per second
        #                                of audio: 44,968 B/path for the 10 s fixtures, but
        #                                832,447 B/path for a 180 s track
        #                                -> binds at roughly 750 paths of 10 s audio, and at
        #                                   roughly 40 paths of 3-minute tracks
        #
        # So stderr binds first and binds early: a few albums of real tracks in one `analyze_all`
        # call will reach it. That is a loud, correctly attributed BackendError which cannot
        # corrupt a value, but callers with large libraries must chunk `analyze_all` -- see its
        # documentation on Extractor. Raising this ceiling is not the fix; the stderr volume is
        # repeated Essentia warning text that is elided to STDERR_MESSAGE_BYTES before it can ever
        # reach a caller, so retaining it whole is waste. Tracked in
        # https://github.com/Lhosb/sonance/issues/6.
        #
        # For the single-path calls this gem is mostly used with, neither stream comes close.
        MAX_STREAM_BYTES = 32 * 1024 * 1024
        STREAM_CHUNK_BYTES = 64 * 1024

        Result = Struct.new(:stdout, :stderr, :exitstatus, :termsig, keyword_init: true)

        def call(command, timeout:)
          stdout_text, stderr_text, status = capture(command, timeout:)
          result(stdout_text, stderr_text, status)
        rescue Errno::ENOENT, Errno::EACCES => e
          raise CommandLaunchError, e.message
        end

        private

        def capture(command, timeout:)
          overflowed = []
          captured = nil

          Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait_thread|
            stdin.close
            captured = pump(stdout, stderr, wait_thread, timeout, overflowed)
          end

          raise_stream_limit!(overflowed.first) unless overflowed.empty?

          captured
        end

        def pump(stdout, stderr, wait_thread, timeout, overflowed)
          readers = start_readers(stdout, stderr, wait_thread, overflowed)
          status = nil

          begin
            Timeout.timeout(timeout) { status = wait_thread.value }
          rescue Timeout::Error
            terminate(wait_thread)
            raise CommandTimeout
          ensure
            stdout_text = collect(readers.fetch(:stdout), stdout)
            stderr_text = collect(readers.fetch(:stderr), stderr)
          end

          [stdout_text, stderr_text, status]
        end

        def start_readers(stdout, stderr, wait_thread, overflowed)
          record_overflow = lambda do |stream_name|
            overflowed << stream_name
            kill_group(wait_thread)
          end

          {
            stdout: bounded_reader(stdout, "stdout", record_overflow),
            stderr: bounded_reader(stderr, "stderr", record_overflow)
          }
        end

        # Reads in bounded chunks instead of a single unbounded `read`. The byte sequence for
        # any output under the ceiling is identical, so the happy path is unchanged.
        def bounded_reader(stream, stream_name, record_overflow)
          Thread.new do
            Thread.current.report_on_exception = false
            buffer = +""
            while (chunk = stream.read(STREAM_CHUNK_BYTES))
              buffer << chunk
              next if buffer.bytesize <= MAX_STREAM_BYTES

              # Kill the child rather than keep draining it, and stop accumulating. The partial
              # buffer is discarded by raise_stream_limit! and never reaches a caller.
              record_overflow.call(stream_name)
              break
            end
            buffer
          end
        end

        # Loud by construction: the truncated buffer is dropped on the floor rather than
        # returned. Silently handing back partial NDJSON would corrupt descriptor values,
        # which is worse than the exhaustion the ceiling prevents.
        def raise_stream_limit!(stream_name)
          raise BackendError,
                "Essentia backend exceeded the #{MAX_STREAM_BYTES} byte #{stream_name} limit; " \
                "the subprocess was terminated and its output discarded"
        end

        # Best-effort: the child frequently exits on its own between crossing the ceiling and
        # this call, and a group whose leader has already reaped can answer ESRCH or, on
        # macOS, EPERM. Either means "already gone", which is the outcome we wanted.
        #
        # PORTABILITY -- do not simplify this rescue to ESRCH alone. Linux answers ESRCH where
        # macOS answers EPERM, so dropping EPERM stays green on Linux CI and reintroduces the
        # bug on macOS. Verified by mutation: dropping EPERM fails on macOS in 10/10 runs.
        def kill_group(wait_thread)
          Process.kill("KILL", -wait_thread.pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        def result(stdout, stderr, status)
          Result.new(stdout:, stderr:, exitstatus: status.exitstatus, termsig: status.termsig)
        end

        def collect(reader, stream)
          return reader.value if reader.join(2)

          stream.close
          reader.kill
          reader.join
          ""
        end

        def terminate(wait_thread)
          Process.kill("TERM", -wait_thread.pid)
          Timeout.timeout(2) { wait_thread.value }
        # Linux reports a vanished process group as ESRCH, while macOS can report EPERM.
        rescue Errno::ESRCH, Errno::EPERM
          nil
        rescue Timeout::Error
          kill_group(wait_thread)
          wait_thread.value
        end
      end

      def initialize(
        models_dir:,
        timeout_per_file: 60,
        python_executable: "python3",
        command_runner: CommandRunner.new
      )
        @models_dir = Pathname(models_dir)
        @timeout_per_file = timeout_per_file
        @python_executable = python_executable.to_s
        @command_runner = command_runner
      end

      def preflight_environment!
        result = run_command(
          [python_executable, "-c", "import essentia.standard"],
          timeout: STARTUP_GRACE
        )
        raise_for_fatal_exit!(result) || true
      rescue CommandTimeout
        raise BackendError, "Essentia environment preflight timed out"
      end

      def preflight_plan!(plan)
        result = with_plan_arguments(plan) do |plan_arguments|
          run_command(
            [
              python_executable,
              SCRIPT_PATH.to_s,
              "--verify",
              "--models-dir",
              models_dir.to_s,
              *plan_arguments
            ],
            timeout: command_timeout
          )
        end
        raise_for_fatal_exit!(result)
        true
      rescue CommandTimeout
        raise BackendError, "Essentia plan preflight timed out"
      end

      def analyze(path, plan:)
        analyze_all([path], plan:).first
      end

      def analyze_all(paths, plan:)
        raise ArgumentError, "plan must be a Sonance::Plan" unless plan.is_a?(Plan)

        pathnames = paths.map { |path| Pathname(path) }
        result = run_analysis(pathnames, plan)
        return process_errors(result, pathnames) if result.exitstatus.nil? && result.termsig

        raise_for_fatal_exit!(result)
        parse_results(result.stdout, pathnames)
      rescue CommandTimeout
        pathnames.map { |pathname| TimeoutError.new("Essentia extraction timed out for #{pathname}") }
      end

      private

      attr_reader :models_dir, :timeout_per_file, :python_executable, :command_runner

      def command_timeout
        STARTUP_GRACE + timeout_per_file
      end

      def batch_command_timeout(path_count)
        STARTUP_GRACE + (timeout_per_file * [path_count, 1].max)
      end

      def run_analysis(pathnames, plan)
        with_plan_arguments(plan) do |plan_arguments|
          run_command(
            [
              python_executable,
              SCRIPT_PATH.to_s,
              *pathnames.map(&:to_s),
              "--models-dir",
              models_dir.to_s,
              *plan_arguments
            ],
            timeout: batch_command_timeout(pathnames.length)
          )
        end
      end

      def with_plan_arguments(plan)
        payload = JSON.generate(plan.to_h)
        return yield(["--plan-json", payload]) if payload.bytesize <= PLAN_ARGUMENT_LIMIT

        # This is a system-tmpdir subprocess handoff, not a durable models_dir artifact.
        Tempfile.create(["sonance-plan", ".json"]) do |file|
          file.write(payload)
          file.flush
          yield(["--plan-file", file.path])
        end
      end

      def run_command(command, timeout:)
        command_runner.call(command, timeout:)
      rescue CommandLaunchError => e
        raise ConfigurationError, "unable to launch Python executable #{python_executable}: #{e.message}"
      end

      def raise_for_fatal_exit!(result)
        return if result.exitstatus&.zero?

        message = truncate_stderr(result.stderr.to_s.strip)
        if result.exitstatus.nil?
          signal = result.termsig ? " by signal #{result.termsig}" : ""
          raise BackendError, "Essentia backend terminated#{signal}"
        end
        message = "Essentia backend exited #{result.exitstatus}" if message.empty?
        error_class = result.exitstatus == 2 ? ConfigurationError : BackendError
        raise error_class, message
      end

      # Keeps the head and the tail with an explicit marker naming the elided byte count, so a
      # reader can tell the message was shortened rather than wondering where the cause went.
      def truncate_stderr(text)
        return text if text.bytesize <= STDERR_MESSAGE_BYTES

        tail_bytes = STDERR_MESSAGE_BYTES - STDERR_MESSAGE_HEAD
        elided = text.bytesize - STDERR_MESSAGE_BYTES
        head = text.byteslice(0, STDERR_MESSAGE_HEAD).scrub
        tail = text.byteslice(-tail_bytes, tail_bytes).scrub

        "#{head}\n[... sonance elided #{elided} bytes of backend stderr ...]\n#{tail}"
      end

      def process_error(result, pathname)
        BackendProcessError.new(
          "Essentia extraction terminated by signal #{result.termsig} for #{pathname}"
        )
      end

      def process_errors(result, pathnames)
        pathnames.map { |pathname| process_error(result, pathname) }
      end

      def parse_results(output, requested_paths)
        lines = output.lines.reject { |line| line.strip.empty? }
        validate_result_count!(lines, requested_paths)
        lines.zip(requested_paths).map { |line, path| parse_line(line, path) }
      rescue JSON::ParserError => e
        raise BackendError, "Essentia backend returned invalid NDJSON: #{e.message}"
      end

      def validate_result_count!(lines, requested_paths)
        return if lines.length == requested_paths.length

        raise BackendError,
              "Essentia backend returned #{lines.length} results for #{requested_paths.length} paths"
      end

      def parse_line(line, requested_path)
        payload = JSON.parse(line)
        unless payload["path"] == requested_path.to_s
          raise BackendError, "Essentia backend returned a result for the wrong path"
        end

        return error_from_payload(payload["error"]) if payload["error"]
        return payload["features"] if payload["features"]

        raise BackendError, "Essentia backend omitted features for #{requested_path}"
      end

      def error_from_payload(error)
        message = error["message"].to_s
        case error["type"]
        when "unreadable_audio"
          UnreadableAudioError.new(message)
        when "inference_error"
          InferenceError.new(message)
        when "malformed_output"
          MalformedOutputError.new(message)
        else
          raise BackendError, "Essentia backend returned unknown error type: #{error['type']}"
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
