module Sonance
  Plan = Data.define(
    :schema_version,
    :loads,
    :graphs,
    :algorithms,
    :emit,
    :required_files
  ) do
    def to_h
      {
        schema_version:,
        loads:,
        graphs:,
        algorithms:,
        emit:,
        required_files:
      }
    end
  end

  # The planner is intentionally one cohesive translation from registry rows to the wire plan.
  # rubocop:disable Metrics/ClassLength
  class Planner
    SCHEMA_VERSION = 1
    GRAPH_ALGORITHMS = {
      tensorflow_predict_musicnn: "TensorflowPredictMusiCNN",
      tensorflow_predict_2d: "TensorflowPredict2D"
    }.freeze

    def initialize(registry:)
      @registry = registry
    end

    def plan_for(descriptors:)
      rows = descriptors.map { |id| registry.fetch(id) }
      graph_models = graph_models_for(rows)
      graph_refs = graph_references(graph_models)
      algorithms, algorithm_refs = algorithm_plan(rows)

      Plan.new(
        schema_version: SCHEMA_VERSION,
        loads: load_plan(graph_models, algorithms),
        graphs: graph_plan(graph_models, graph_refs),
        algorithms:,
        emit: emit_plan(rows, graph_refs, algorithm_refs),
        required_files: graph_models.map(&:filename).freeze
      )
    end

    private

    attr_reader :registry

    def graph_models_for(rows)
      requested = rows.filter_map do |row|
        row.produced_by.model if row.produced_by.is_a?(FromModel)
      end.uniq
      embeddings = requested.filter_map { |id| registry.model(id).embedding }.uniq
      (embeddings + requested).uniq.map { |id| registry.model(id) }
    end

    def graph_references(models)
      counters = Hash.new(0)

      models.to_h do |model|
        kind = model.embedding ? :h : :emb
        ref = "#{kind}#{counters[kind]}"
        counters[kind] += 1
        [model.id, ref]
      end
    end

    def graph_plan(models, references)
      models.map do |model|
        graph = {
          ref: references.fetch(model.id),
          file: model.filename,
          algorithm: graph_algorithm(model.algorithm),
          output: model.output_node
        }
        if model.embedding
          graph[:input] = { graph: references.fetch(model.embedding) }
        else
          graph[:sample_rate] = model.sample_rate
          graph[:input] = { audio: model.sample_rate }
        end
        graph.freeze
      end.freeze
    end

    def graph_algorithm(id)
      GRAPH_ALGORITHMS.fetch(id) do
        raise ConfigurationError,
              "unknown graph algorithm: #{id}; valid algorithms: #{GRAPH_ALGORITHMS.keys.join(', ')}"
      end
    end

    def algorithm_plan(rows)
      definitions = rows.filter_map do |row|
        row.produced_by if row.produced_by.is_a?(FromAlgorithm)
      end
      definitions = definitions.uniq { |definition| algorithm_key(definition) }
      references = definitions.each_with_index.to_h do |definition, index|
        [algorithm_key(definition), "a#{index}"]
      end
      plans = definitions.map do |definition|
        {
          ref: references.fetch(algorithm_key(definition)),
          name: definition.name,
          params: definition.params,
          sample_rate: definition.sample_rate
        }.freeze
      end.freeze

      [plans, references]
    end

    def algorithm_key(definition)
      [definition.name, definition.params]
    end

    def load_plan(graph_models, algorithms)
      sample_rates = graph_models.map(&:sample_rate)
      sample_rates.concat(algorithms.map { |algorithm| algorithm.fetch(:sample_rate) })
      sample_rates.uniq.map { |sample_rate| { sample_rate: }.freeze }.freeze
    end

    def emit_plan(rows, graph_refs, algorithm_refs)
      rows.map do |row|
        source = row.produced_by
        if source.is_a?(FromModel)
          emit_from_model(row, source, graph_refs)
        else
          {
            id: row.id.to_s,
            kind: row.kind.to_s,
            from: algorithm_refs.fetch(algorithm_key(source)),
            take: { output: source.output }.freeze
          }.freeze
        end
      end.freeze
    end

    def emit_from_model(descriptor, source, graph_refs)
      model = registry.model(source.model)
      emit = {
        id: descriptor.id.to_s,
        kind: descriptor.kind.to_s,
        from: graph_refs.fetch(model.id),
        take: projection(model, source.select),
        reduce: model.reduction.to_s
      }
      emit.freeze
    end

    def projection(model, selection)
      return nil unless selection

      selected_class = selection.fetch(:class)
      raise ConfigurationError, "no classes recorded for #{model.id} (output #{model.output_node})" unless model.classes

      index = model.classes.index(selected_class)
      raise ConfigurationError, "unknown class #{selected_class.inspect} for #{model.id}" unless index

      { index: }.freeze
    end
  end
  # rubocop:enable Metrics/ClassLength
end
