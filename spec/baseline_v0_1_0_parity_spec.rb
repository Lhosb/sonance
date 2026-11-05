require "fileutils"

baseline_fixture_names =
  Pathname(__dir__).join("fixtures/sonance/baseline_v0_1_0").glob("*.json").map(&:basename).sort
raise "no baseline fixtures discovered" if baseline_fixture_names.empty?

RSpec.describe "sonance v0.1.0 algebraic parity" do
  let(:fixture_root) { Pathname(__dir__).join("fixtures/sonance") }
  let(:baseline_dir) { fixture_root.join("baseline_v0_1_0") }
  let(:golden_dir) { fixture_root.join("golden") }
  let(:head_mapping) do
    {
      "danceability" => "danceability_musicnn",
      "mood_acoustic" => "mood_acoustic_musicnn",
      "mood_relaxed" => "mood_relaxed_musicnn",
      "mood_happy" => "mood_happy_musicnn",
      "valence" => "valence_emomusic",
      "arousal" => "arousal_emomusic"
    }
  end

  baseline_fixture_names.each do |filename|
    it "preserves #{filename} through the native-value golden" do
      expect(assert_parity(filenames: [filename])).to eq(6)
    end
  end

  # The decimal literals are independent calibration controls for the 1e-4 bound.
  # rubocop:disable Style/ExponentialNotation
  it "accepts a calibration perturbation just inside the parity bound" do
    with_perturbed_baseline(relative_delta: 0.9e-4) do |baseline_root|
      expect(assert_parity(baseline_root:)).to eq(24)
    end
  end

  it "rejects a calibration perturbation just outside the parity bound" do
    with_perturbed_baseline(relative_delta: 1.1e-4) do |baseline_root|
      expect { assert_parity(baseline_root:) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /chirp\.json mood_happy drifted/)
    end
  end
  # rubocop:enable Style/ExponentialNotation

  def with_perturbed_baseline(relative_delta:)
    Dir.mktmpdir do |directory|
      baseline_root = Pathname(directory)
      baseline_dir.glob("*.json").each { |fixture| FileUtils.cp(fixture, baseline_root) }
      path = baseline_root.join("chirp.json")
      baseline = JSON.parse(path.read)
      baseline["mood_happy"] += relative_delta * baseline.fetch("mood_happy").abs
      path.write("#{JSON.pretty_generate(baseline)}\n")

      yield baseline_root
    end
  end

  # rubocop:disable-next Metrics/AbcSize
  def assert_parity(filenames: baseline_dir.glob("*.json").map(&:basename).sort, baseline_root: baseline_dir)
    comparisons = 0

    filenames.each do |filename|
      baseline = JSON.parse(baseline_root.join(filename).read)
      golden = JSON.parse(golden_dir.join(filename).read)

      head_mapping.each do |baseline_head, golden_head|
        expected = baseline.fetch(baseline_head)
        raw = golden.fetch(golden_head)
        actual = %w[valence arousal].include?(baseline_head) ? (raw - 1.0) / 8.0 : raw
        tolerance = [1e-4 * expected.abs, 1e-10].max
        comparisons += 1

        expect(actual).to be_within(tolerance).of(expected),
                          "#{filename} #{baseline_head} drifted"
      end
    end

    comparisons
  end
end
