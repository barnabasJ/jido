defmodule Jido.Ash.Slice.Transformers.GenerateActionModules do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Jido.Ash.Slice.Info
  alias Jido.Ash.Slice.PersistenceEntry
  alias Jido.Ash.Slice.SignalEntry
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  @spec transform(dsl_state :: map()) :: {:ok, map()} | {:error, term()}
  def transform(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :module)
    slice_opts = slice_opts(dsl_state)

    ash_actions = Transformer.get_entities(dsl_state, [:actions])
    attributes = Transformer.get_entities(dsl_state, [:attributes])

    jido_slice_entities = Transformer.get_entities(dsl_state, [:jido_slice])
    signal_entries = Enum.filter(jido_slice_entities, &match?(%SignalEntry{}, &1))
    persistence_entries = Enum.filter(jido_slice_entities, &match?(%PersistenceEntry{}, &1))

    slice_generation = slice_generation(resource, attributes, persistence_entries)

    generic_signals = generic_signal_entries(signal_entries, ash_actions)

    generated =
      generic_signals
      |> Enum.uniq_by(& &1.action)
      |> Enum.map(&generated_entry(resource, ash_actions, slice_opts.name, &1))

    routes = Enum.map(generic_signals, &generated_route(resource, &1))
    block = build_modules(resource, slice_generation, slice_opts, generated, routes)

    dsl_state =
      dsl_state
      |> Transformer.persist(
        :jido_generated_slice_module,
        generated_slice_module(slice_generation)
      )
      |> Transformer.persist(:jido_generated_action_modules, Enum.map(generated, & &1.module))
      |> Transformer.persist(
        :jido_generated_action_modules_by_action,
        Map.new(generated, &{&1.action, &1.module})
      )
      |> Transformer.eval([], block)

    {:ok, dsl_state}
  rescue
    error -> {:error, error}
  end

  @impl Spark.Dsl.Transformer
  def after?(Ash.Resource.Transformers.ValidateRelationshipAttributes), do: true

  def after?(_transformer), do: false

  defp generic_signal_entries(signals, ash_actions) do
    Enum.filter(signals, fn %SignalEntry{action: action} ->
      match?(%{type: :action}, action_by_name(ash_actions, action))
    end)
  end

  defp generated_route(resource, %SignalEntry{} = signal) do
    %{module: generated_module(resource, signal.action), signal_type: signal.type}
  end

  defp generated_entry(resource, ash_actions, slice_name, %SignalEntry{} = signal) do
    action = action_by_name(ash_actions, signal.action)

    %{
      action: signal.action,
      ash_action: action,
      module: generated_module(resource, signal.action),
      slice_name: slice_name,
      signal_type: signal.type,
      schema: []
    }
  end

  defp slice_opts(dsl_state) do
    %{
      name: Transformer.get_option(dsl_state, [:jido_slice], :name),
      description: Transformer.get_option(dsl_state, [:jido_slice], :description),
      category: Transformer.get_option(dsl_state, [:jido_slice], :category),
      vsn: Transformer.get_option(dsl_state, [:jido_slice], :vsn),
      otp_app: Transformer.get_option(dsl_state, [:jido_slice], :otp_app),
      tags: Transformer.get_option(dsl_state, [:jido_slice], :tags, []) || []
    }
  end

  defp action_by_name(ash_actions, name) do
    Enum.find(ash_actions, &(&1.name == name))
  end

  defp generated_module(resource, action) do
    Module.concat([resource, Jido, Macro.camelize(to_string(action))])
  end

  defp generated_slice_module_name(resource) do
    Module.concat([resource, Jido, Slice])
  end

  defp slice_generation(resource, attributes, persistence_entries) do
    {:ok,
     %{
       module: generated_slice_module_name(resource),
       schema: Info.state_schema_from_attributes(attributes),
       persistence_fields:
         Info.persistence_fields_from_attributes(attributes, persistence_entries)
     }}
  rescue
    ArgumentError -> :skip
  end

  defp generated_slice_module({:ok, %{module: module}}), do: module
  defp generated_slice_module(:skip), do: nil

  defp build_modules(resource, slice_generation, slice_opts, generated, routes) do
    blocks =
      Enum.map(generated, &module_block(resource, &1)) ++
        slice_module_blocks(slice_generation, slice_opts, routes)

    quote do
      (unquote_splicing(blocks))
    end
  end

  defp module_block(resource, generated) do
    %{
      action: action,
      ash_action: ash_action,
      module: module,
      slice_name: slice_name,
      schema: schema
    } = generated

    action_name = action_name(resource, slice_name, action)

    description =
      ash_action.description || "Ash-backed slice reducer for #{inspect(resource)}.#{action}"

    quote location: :keep do
      defmodule unquote(module) do
        @moduledoc false

        use Jido.Action

        action do
          name unquote(action_name)
          description unquote(description)
          category "ash.slice.reducer"
          tags ["ash", "slice", "reducer"]
          schema unquote(Macro.escape(schema))
        end

        @resource unquote(resource)
        @ash_action unquote(action)
        @impl Jido.Action
        @spec run(signal :: Jido.Signal.t() | map(), slice :: map(), opts :: map(), ctx :: map()) ::
                {:ok, map(), [Jido.Directives.t()]} | {:error, term()}
        def run(signal, slice, opts, ctx) do
          payload = Jido.Ash.Slice.ReducerAdapter.payload(signal)
          ash_opts = Jido.Ash.Slice.ReducerAdapter.ash_opts(ctx, opts, slice, signal)

          @resource
          |> Ash.ActionInput.for_action(@ash_action, payload, ash_opts)
          |> Ash.run_action(ash_opts)
          |> Jido.Ash.Slice.ReducerAdapter.to_action_result(slice)
        end
      end
    end
  end

  defp action_name(resource, slice_name, action) do
    slice_name = slice_name || resource |> Module.split() |> List.last() |> Macro.underscore()
    "#{slice_name}_#{action}"
  end

  defp slice_module_blocks(:skip, _slice_opts, _generated), do: []

  defp slice_module_blocks(
         {:ok, %{module: slice_module, schema: schema, persistence_fields: persistence_fields}},
         slice_opts,
         generated
       ) do
    [slice_module_block(slice_module, schema, persistence_fields, slice_opts, generated)]
  end

  defp slice_module_block(slice_module, schema, persistence_fields, slice_opts, generated) do
    route_blocks = Enum.map(generated, &route_block/1)
    option_blocks = slice_option_blocks(slice_opts)

    quote location: :keep do
      defmodule unquote(slice_module) do
        @moduledoc false

        use Jido.Slice

        @behaviour Jido.Persist.Transform
        @persistence_fields unquote(Macro.escape(persistence_fields))

        slice do
          name unquote(slice_opts.name)
          unquote_splicing(option_blocks)
          schema unquote(Macro.escape(schema))
        end

        signal_routes do
          (unquote_splicing(route_blocks))
        end

        @impl Jido.Persist.Transform
        @spec externalize(slice_value :: term()) :: term()
        def externalize(slice_value) do
          Jido.Ash.Slice.Persistence.externalize(slice_value, @persistence_fields)
        end

        @impl Jido.Persist.Transform
        @spec reinstate(stored_value :: term()) :: term()
        def reinstate(stored_value) do
          Jido.Ash.Slice.Persistence.reinstate(stored_value, @persistence_fields)
        end
      end
    end
  end

  defp route_block(%{module: module, signal_type: signal_type}) do
    quote do
      route unquote(signal_type), unquote(module)
    end
  end

  defp slice_option_blocks(slice_opts) do
    []
    |> maybe_option(:description, slice_opts.description)
    |> maybe_option(:category, slice_opts.category)
    |> maybe_option(:vsn, slice_opts.vsn)
    |> maybe_option(:otp_app, slice_opts.otp_app)
    |> maybe_option(:tags, slice_opts.tags)
    |> Enum.reverse()
  end

  defp maybe_option(blocks, _name, nil), do: blocks
  defp maybe_option(blocks, :tags, []), do: blocks

  defp maybe_option(blocks, name, value) do
    [quote(do: unquote(name)(unquote(value))) | blocks]
  end
end
