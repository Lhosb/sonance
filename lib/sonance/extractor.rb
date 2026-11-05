require "pathname"

module Sonance
  class Extractor
    # The final parameter is an internal seam for keeping model verification pure in unit tests.
    # rubocop:disable-next Metrics/ParameterLists
    def initialize(
      models_dir:,
      timeout_per_file: 60,
      python_executable: "python3",
      backend: nil,
      registry: Registry.default,
      model_store: nil
    )
      @registry = registry
      @planner = Planner.new(registry:)
      @analysis_builder = AnalysisBuilder.new(registry:)
      @backend = backend || Backends::EssentiaPython.new(
        models_dir:,
        timeout_per_file:,
        python_executable:
      )
      @model_store = model_store || ModelStore.new(models_dir, registry:)
      @environment_verified = false
      @verified_descriptors = Set.new
    end

    # Verifies the runtime and model files required by a descriptor set.
    #
    # @param descriptors [Array<Symbol, String>] descriptor ids to verify
    # @return [true]
    # @raise [ConfigurationError, BackendError] when the runtime or required models are unavailable
    def verify!(descriptors:)
      wanted = descriptors.to_set(&:to_sym)
      verify_environment!
      return true if wanted.subset?(verified_descriptors)

      plan = plan_for(descriptors:)
      model_store.verify!(filenames: plan.required_files)
      backend.preflight_plan!(plan)
      verified_descriptors.merge(wanted)
      true
    end

    # Builds the immutable extraction plan for a descriptor set.
    #
    # @param descriptors [Array<Symbol, String>] descriptor ids to plan
    # @return [Plan]
    # @raise [ConfigurationError] when a descriptor or graph algorithm is unknown
    def plan_for(descriptors:)
      planner.plan_for(descriptors:)
    end

    # Extracts descriptors from one audio file.
    #
    # @param path [String, Pathname] audio path
    # @param descriptors [Array<Symbol, String>] descriptor ids to extract
    # @return [Analysis]
    # @raise [TrackError] when the file cannot be analyzed
    # @raise [FatalError] when configuration, the backend, or its output schema is invalid
    def analyze(path, descriptors:)
      result = analyze_all([path], descriptors:).first
      raise result.error unless result.ok?

      result.analysis
    end

    # Extracts descriptors from multiple audio files while preserving input order.
    #
    # The whole batch runs through one backend subprocess, so its stdout and stderr both grow
    # linearly with `paths.length` and are subject to
    # {Backends::EssentiaPython::CommandRunner::MAX_STREAM_BYTES}. Backend stderr dominates and
    # scales with audio duration, so the ceiling is reached at roughly 750 paths of 10-second
    # audio and roughly 40 paths of 3-minute tracks. Exceeding it raises a `BackendError` naming
    # the limit; it cannot truncate or corrupt a value.
    #
    # **Callers processing a large library should chunk**, for example
    # `paths.each_slice(25).flat_map { |slice| extractor.analyze_all(slice, descriptors:) }`.
    # Chunking is left to the caller because the right slice size depends on track duration and
    # on how the caller wants a mid-batch failure handled, and because every chunk pays the
    # backend's process and model-load startup again.
    #
    # @param paths [Array<String, Pathname>] audio paths
    # @param descriptors [Array<Symbol, String>] descriptor ids to extract
    # @return [Array<Result>] successful analyses and returned per-track errors
    # @raise [FatalError] when configuration, the backend, or its output schema is invalid
    def analyze_all(paths, descriptors:)
      normalized_paths = paths.map { |path| Pathname(path) }
      verify!(descriptors:)
      plan = plan_for(descriptors:)
      requested = descriptors.map(&:to_sym)

      if backend.respond_to?(:analyze_all)
        outcomes = backend.analyze_all(normalized_paths, plan:)
        normalized_paths.zip(outcomes).map do |path, outcome|
          result_for_outcome(path, requested, outcome)
        end
      else
        normalized_paths.map do |path|
          result_for_outcome(path, requested, backend.analyze(path, plan:))
        end
      end
    end

    private

    attr_reader :analysis_builder, :backend, :model_store, :planner, :verified_descriptors

    def verify_environment!
      return if @environment_verified

      backend.preflight_environment!
      @environment_verified = true
    end

    def result_for_values(path, requested, raw_values)
      analysis = analysis_builder.call(requested:, raw_values:)
      Result.new(path:, analysis:)
    rescue MalformedOutputError => e
      Result.new(path:, error: e)
    end

    def result_for_outcome(path, requested, outcome)
      return Result.new(path:, error: outcome) if outcome.is_a?(TrackError)

      result_for_values(path, requested, outcome)
    end
  end
end
