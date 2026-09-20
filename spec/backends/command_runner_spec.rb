require "rbconfig"

RSpec.describe Sonance::Backends::EssentiaPython::CommandRunner do
  it "terminates the subprocess group and returns promptly on timeout" do
    runner = described_class.new
    child_pid = nil

    Dir.mktmpdir do |dir|
      pid_file = File.join(dir, "child.pid")
      script = <<~RUBY
        child = spawn(#{RbConfig.ruby.inspect}, "-e", "sleep 3")
        File.write(ARGV.fetch(0), child)
        sleep 3
      RUBY
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { runner.call([RbConfig.ruby, "-e", script, pid_file], timeout: 0.2) }
        .to raise_error(Sonance::Backends::EssentiaPython::CommandTimeout)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      child_pid = Integer(File.read(pid_file))
      expect(elapsed).to be < 1.5
      expect(process_gone?(child_pid)).to be(true)
    end
  ensure
    begin
      Process.kill("KILL", child_pid) if child_pid
    rescue Errno::ESRCH
      nil
    end
  end

  it "treats EPERM while sending TERM as an already terminated process group" do
    runner = described_class.new
    signals = []

    allow(Process).to receive(:kill).and_wrap_original do |original, signal, pid|
      signals << signal
      result = original.call(signal, pid)
      raise Errno::EPERM if signal == "TERM"

      result
    end

    expect { runner.call([RbConfig.ruby, "-e", "sleep 3"], timeout: 0.05) }
      .to raise_error(Sonance::Backends::EssentiaPython::CommandTimeout)
    expect(signals).to eq(["TERM"])
  end

  it "treats EPERM after termination times out as an already terminated process group" do
    runner = described_class.new
    signals = []
    termination_timeout_entered = false

    allow(Timeout).to receive(:timeout).and_wrap_original do |original, duration, &block|
      if duration == 2
        termination_timeout_entered = true
        raise Timeout::Error
      end

      original.call(duration, &block)
    end
    allow(Process).to receive(:kill).and_wrap_original do |original, signal, pid|
      signals << signal
      next 1 if signal == "TERM"

      original.call(signal, pid)
      raise Errno::EPERM
    end

    expect { runner.call([RbConfig.ruby, "-e", "sleep 3"], timeout: 0.05) }
      .to raise_error(Sonance::Backends::EssentiaPython::CommandTimeout)
    expect(termination_timeout_entered).to be(true)
    expect(signals).to eq(%w[TERM KILL])
  end

  # Bounds are exercised through stub_const at a small size so the boundary can be hit
  # exactly. The real ceiling is asserted separately below, so these are not testing a
  # constant that only exists in the spec.
  describe "bounded stream reads" do
    let(:runner) { described_class.new }
    let(:limit) { 4096 }

    before do
      stub_const("#{described_class}::MAX_STREAM_BYTES", limit)
      stub_const("#{described_class}::STREAM_CHUNK_BYTES", 1024)
    end

    def write_bytes(count, stream:)
      runner.call(
        [RbConfig.ruby, "-e", "#{stream}.write('x' * #{count}); #{stream}.flush"],
        timeout: 10
      )
    end

    { "STDOUT" => "stdout", "STDERR" => "stderr" }.each do |stream, name|
      it "accepts #{name} of exactly the limit" do
        result = write_bytes(limit, stream:)

        expect(result.exitstatus).to eq(0)
        expect(result.public_send(name).bytesize).to eq(limit)
      end

      it "raises a BackendError naming the limit for #{name} one byte past it" do
        expect { write_bytes(limit + 1, stream:) }.to raise_error(
          Sonance::BackendError,
          /exceeded the #{limit} byte #{name} limit.*terminated and its output discarded/m
        )
      end
    end

    it "discards the partial buffer rather than returning truncated output" do
      expect { write_bytes(limit * 4, stream: "STDOUT") }
        .to raise_error(Sonance::BackendError)
    end

    it "terminates a subprocess that keeps writing after the limit" do
      script = "loop { STDOUT.write('x' * 8192) }"
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { runner.call([RbConfig.ruby, "-e", script], timeout: 10) }
        .to raise_error(Sonance::BackendError, /exceeded the #{limit} byte stdout limit/)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      expect(elapsed).to be < 5
    end

    it "leaves output under the limit byte-identical" do
      payload = "line\n" * 100
      result = runner.call(
        [RbConfig.ruby, "-e", "STDOUT.write(#{payload.inspect})"],
        timeout: 10
      )

      expect(result.stdout).to eq(payload)
      expect(result.exitstatus).to eq(0)
    end
  end

  # Non-vacuity floor: the boundary examples above stub the ceiling, so assert the shipped
  # value independently. Without this they would pass against any constant, including none.
  it "ships a stream ceiling large enough never to bite a realistic batch" do
    expect(described_class::MAX_STREAM_BYTES).to eq(32 * 1024 * 1024)
    expect(described_class::STREAM_CHUNK_BYTES).to be < described_class::MAX_STREAM_BYTES
  end

  def process_gone?(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      Process.kill(0, pid)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    rescue Errno::ESRCH
      return true
    end
  end
end
