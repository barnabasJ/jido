defmodule Jido.Ash.Slice.Transformers.GenerateActionModules do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Jido.Ash.Slice.SignalEntry
  alias Spark.Dsl.Transformer

  @impl Spark.Dsl.Transformer
  @spec transform(dsl_state :: map()) :: {:ok, map()} | {:error, term()}
  def transform(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :module)
    slice_name = Transformer.get_option(dsl_state, [:jido_slice], :name)

    ash_actions = Transformer.get_entities(dsl_state, [:actions])

    generated =
      dsl_state
      |> Transformer.get_entities([:jido_slice])
      |> generic_signal_entries(ash_actions)
      |> Enum.map(&generated_entry(resource, ash_actions, slice_name, &1))

    block = build_modules(resource, generated)

    dsl_state =
      dsl_state
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
    signals
    |> Enum.filter(fn %SignalEntry{action: action} ->
      match?(%{type: :action}, action_by_name(ash_actions, action))
    end)
    |> Enum.uniq_by(& &1.action)
  end

  defp generated_entry(resource, ash_actions, slice_name, %SignalEntry{} = signal) do
    action = action_by_name(ash_actions, signal.action)

    %{
      action: signal.action,
      ash_action: action,
      module: generated_module(resource, signal.action),
      slice_name: slice_name,
      schema: []
    }
  end

  defp action_by_name(ash_actions, name) do
    Enum.find(ash_actions, &(&1.name == name))
  end

  defp generated_module(resource, action) do
    Module.concat([resource, Jido, Macro.camelize(to_string(action))])
  end

  defp build_modules(_resource, []), do: quote(do: nil)

  defp build_modules(resource, generated) do
    blocks = Enum.map(generated, &module_block(resource, &1))

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
end
