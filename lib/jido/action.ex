defmodule Jido.Action do
  @moduledoc """
  An Action reduces a slice of agent state in response to a signal.

  ## Callback shape

      run(signal, slice, opts, ctx) ::
        {:ok, new_slice, [directive]}
        | {:error, reason}

  Always a 3-tuple on success — even when no directives are emitted, the
  list is empty. There is no `{:ok, slice}` two-arg variant and no
  `{:error, reason, [directive]}` variant; if it failed, it failed —
  emit observability via middleware on the failure path.

  - `signal`: the `Jido.Signal.t()` that triggered the action. Action type
    is `signal.type`; payload is `signal.data`. Per-signal runtime ctx is
    at `signal.extensions[:jido_ctx]` (already extracted and passed as the
    `ctx` arg).
  - `slice`: the current value of `agent.state[path]`, where `path` is the
    action's declared `path:` option. Actions own their slice's next value —
    return the full new slice, not a patch.
  - `opts`: static options attached at route registration. From
    `{"work.start", {MyAction, %{max_retries: 3}}}`, `opts = %{max_retries: 3}`.
    Defaults to `%{}`.
  - `ctx`: per-signal runtime context (user, trace, tenant, parent,
    partition, agent_id). Propagates to emitted signals' `extensions[:jido_ctx]`
    by default; middleware can augment or strip before forwarding.

  Bare-atom or string `reason` values returned in `{:error, reason}` are
  wrapped into `%Jido.Error{}` at the cmd boundary via
  `Jido.Error.from_term/1`, so consumers always see a structured error.

  ## Defining an Action

      defmodule Counter.Increment do
        use Jido.Action

        action do
          name "increment"
          path :counter
          schema [by: [type: :integer, default: 1]]
        end

        @impl true
        def run(%Jido.Signal{data: %{by: by}}, slice, _opts, _ctx) do
          {:ok, %{slice | count: (slice[:count] || 0) + by}, []}
        end
      end

  ## Parameter and Output Validation

  > **Note on Validation:** Validation is intentionally open — only fields
  > specified in `schema` and `output_schema` are validated. Unspecified
  > fields are not validated, allowing easier action composition and
  > pass-through of additional parameters.
  """

  use Spark.Dsl, default_extensions: [extensions: [Jido.Dsl.Action]]

  alias Jido.Action.Error

  @schema Zoi.struct(
            __MODULE__,
            %{
              name:
                Zoi.string(description: "The name of the Action")
                |> Zoi.refine({Jido.Action.Util, :validate_name, []}),
              description: Zoi.string(description: "Description") |> Zoi.optional(),
              category: Zoi.string(description: "Category") |> Zoi.optional(),
              tags: Zoi.list(Zoi.string(), description: "Tags") |> Zoi.default([]),
              vsn: Zoi.string(description: "Version") |> Zoi.optional(),
              schema:
                Zoi.any(description: "NimbleOptions or Zoi schema for validating Action input")
                |> Zoi.default([]),
              output_schema:
                Zoi.any(description: "NimbleOptions or Zoi schema for validating Action output")
                |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec validate_io_schema(term(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def validate_io_schema(value, _opts \\ []) do
    case Jido.Action.Schema.validate_config_schema(value, []) do
      :ok -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      @behaviour Jido.Action
    end
  end

  @doc """
  Executes the Action.

  Implementing modules must define `run/4`, returning
  `{:ok, new_slice, [directive]} | {:error, reason}`. See module doc.
  """
  @callback run(
              signal :: Jido.Signal.t() | map(),
              slice :: term(),
              opts :: map(),
              ctx :: map()
            ) ::
              {:ok, new_slice :: term(), [Jido.Directives.t()]}
              | {:error, term()}

  @callback on_before_validate_params(params :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_validate_params(params :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_before_validate_output(output :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_validate_output(output :: map()) :: {:ok, map()} | {:error, any()}
  @callback on_after_run(result :: {:ok, term(), [Jido.Directives.t()]} | {:error, any()}) ::
              {:ok, term(), [Jido.Directives.t()]} | {:error, any()}

  @optional_callbacks [
    on_before_validate_params: 1,
    on_after_validate_params: 1,
    on_before_validate_output: 1,
    on_after_validate_output: 1,
    on_after_run: 1
  ]

  @doc """
  Raises an error indicating that Actions cannot be defined at runtime.
  """
  @spec new() :: {:error, Exception.t()}
  @spec new(map() | keyword()) :: {:error, Exception.t()}
  def new, do: new(%{})

  def new(_map_or_kwlist) do
    "Actions should not be defined at runtime"
    |> Error.config_error()
    |> then(&{:error, &1})
  end
end
