RSpec.describe Sonance::Planner do
  subject(:planner) { described_class.new(registry: Sonance::Registry.default) }

  fixture_root = Pathname(__dir__).join("fixtures/sonance/plans")

  {
    "musicnn_only" => %i[mood_happy_musicnn],
    "algorithm_only" => %i[bpm_rhythm2013],
    "mixed" => %i[bpm_rhythm2013 mood_happy_musicnn],
    "emomusic" => %i[valence_emomusic]
  }.each do |fixture_name, descriptors|
    it "matches the committed #{fixture_name} plan fixture" do
      expected = JSON.parse(
        fixture_root.join("#{fixture_name}.json").read,
        symbolize_names: true
      )

      expect(planner.plan_for(descriptors:).to_h).to eq(expected)
    end
  end

  it "omits model graphs for an algorithm-only request" do
    expect(planner.plan_for(descriptors: [:bpm_rhythm2013]).graphs).to be_empty
  end

  it "shares one algorithm instance across descriptors selecting different outputs" do
    plan = planner.plan_for(descriptors: %i[bpm_rhythm2013 beat_confidence_rhythm2013])
    single_descriptor_plan = planner.plan_for(descriptors: [:bpm_rhythm2013])

    expect(plan.algorithms).not_to be_empty
    expect(plan.algorithms.count { |algorithm| algorithm.fetch(:name) == "RhythmExtractor2013" }).to eq(1)
    expect(plan.emit.map { |emission| emission.fetch(:from) }.uniq).to eq(["a0"])
    expect(plan.emit.map { |emission| emission.fetch(:take).fetch(:output) }).to contain_exactly("bpm", "confidence")
    expect(single_descriptor_plan.algorithms.count).to eq(1)
  end

  it "keeps separate algorithm instances when their parameters differ" do
    bpm = Sonance::Registry.default.fetch(:bpm_rhythm2013)
    confidence = Sonance::Registry.default.fetch(:beat_confidence_rhythm2013)
    confidence = confidence.with(
      produced_by: confidence.produced_by.with(params: { method: "degara" }.freeze)
    )
    registry = Sonance::Registry.new(
      models: Sonance::Registry.default.models,
      descriptors: [bpm, confidence]
    )

    plan = described_class.new(registry:).plan_for(
      descriptors: %i[bpm_rhythm2013 beat_confidence_rhythm2013]
    )

    expect(plan.algorithms.map { |algorithm| algorithm.fetch(:params) }).to contain_exactly(
      { method: "multifeature" },
      { method: "degara" }
    )
  end

  it "pins the current inverted relaxed projection pending the Phase B upstream JSON gate" do
    plan = planner.plan_for(descriptors: [:mood_relaxed_musicnn])

    expect(plan.emit.fetch(0).fetch(:take)).to eq(index: 1)
  end

  # rubocop:disable Naming/VariableNumber
  it "rejects class projection from the MusiCNN embedding output" do
    descriptor = Sonance::Descriptor.new(
      id: :invalid_musicnn_class,
      kind: :scalar,
      produced_by: Sonance::FromModel.new(
        model: :msd_musicnn_1,
        select: { class: "happy" }
      ),
      native_range: nil,
      range_kind: :unbounded,
      sanity_range: nil,
      units: :unitless,
      shape: nil,
      notes: "Invalid projection used to pin the output contract."
    )
    registry = Sonance::Registry.new(
      models: Sonance::Registry.default.models,
      descriptors: [descriptor]
    )

    expect do
      described_class.new(registry:).plan_for(descriptors: [:invalid_musicnn_class])
    end.to raise_error(
      Sonance::ConfigurationError,
      %r{no classes recorded for msd_musicnn_1.*output model/dense/BiasAdd}
    )
  end
  # rubocop:enable Naming/VariableNumber

  it "returns immutable required files" do
    plan = planner.plan_for(descriptors: [:mood_happy_musicnn])

    expect(plan.required_files).to be_frozen
    expect { plan.required_files << "extra.pb" }.to raise_error(FrozenError)
  end

  it "loads model and algorithm sample rates in dependency order" do
    plan = planner.plan_for(descriptors: %i[bpm_rhythm2013 mood_happy_musicnn])

    expect(plan.loads.map { |load| load.fetch(:sample_rate) }).to eq([16_000, 44_100])
  end

  it "lists only files required by the requested descriptors" do
    expect(planner.plan_for(descriptors: [:bpm_rhythm2013]).required_files).to eq([])
    expect(planner.plan_for(descriptors: [:mood_happy_musicnn]).required_files).to eq(
      ["msd-musicnn-1.pb", "mood_happy-msd-musicnn-1.pb"]
    )
  end

  # rubocop:disable Naming/VariableNumber
  it "raises a gem configuration error for an unknown graph algorithm" do
    models = Sonance::Registry.default.models.map do |model|
      model.id == :msd_musicnn_1 ? model.with(algorithm: :custom_graph) : model
    end
    registry = Sonance::Registry.new(
      models:,
      descriptors: Sonance::Registry.default.descriptors
    )

    expect do
      described_class.new(registry:).plan_for(descriptors: [:embedding_musicnn])
    end.to raise_error(
      Sonance::ConfigurationError,
      /unknown graph algorithm: custom_graph.*valid algorithms:.*tensorflow_predict_musicnn/
    )
  end
  # rubocop:enable Naming/VariableNumber
end
