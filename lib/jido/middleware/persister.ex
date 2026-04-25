defmodule Jido.Middleware.Persister do
  @moduledoc """
  Hibernate / thaw middleware.

  On `jido.agent.lifecycle.starting` Persister blocks synchronously on
  `Jido.Persist.thaw/3` and replaces `ctx.agent` with the rehydrated struct
  before delegating to the rest of the chain. Any slice/plugin module that
  implements `Jido.Persist.Transform` has `reinstate/1` applied so the
  in-memory shape is restored from its serialized form. Failures emit a
  `jido.persist.thaw.failed` signal as a side effect; the chain still runs.

  On `jido.agent.lifecycle.stopping` Persister walks every declared
  slice/plugin and calls `externalize/1` where the behaviour is implemented
  (defaulting to passthrough), then synchronously persists the result via
  `Jido.Persist.hibernate/4`. Hibernate IO runs on the terminate path —
  callers must size the supervisor's shutdown timeout accordingly.

  ## Configuration

  Pass options as a per-registration map:

      middleware: [
        {Jido.Middleware.Persister, %{
          storage: {MyStorage, my_opts},
          persistence_key: "my-agent"
        }}
      ]

  When `:storage` is `nil`, the middleware is a pass-through for every
  signal — useful in tests that build the chain without persistence.
  """

  use Jido.Middleware

  alias Jido.Agent.Directive
  alias Jido.Signal

  @starting_type "jido.agent.lifecycle.starting"
  @stopping_type "jido.agent.lifecycle.stopping"

  @impl Jido.Middleware
  def on_signal(%Signal{type: @starting_type} = sig, ctx, opts, next) do
    # Stash persister opts in the process dict so the lifecycle module can
    # call `persist_cron_specs/2` for write-through durability without
    # peering into the closed-over middleware chain.
    Process.put(:jido_persister_opts, opts)

    case opts[:storage] do
      nil ->
        next.(sig, ctx)

      storage ->
        agent_module = ctx.agent_module
        key = opts[:persistence_key]

        case Jido.Persist.thaw(storage, agent_module, key) do
          {:ok, raw_agent} ->
            thawed_agent = apply_reinstate(raw_agent, agent_module)
            {final_ctx, dirs} = next.(sig, %{ctx | agent: thawed_agent})

            {final_ctx,
             dirs ++
               [emit("jido.persist.thaw.completed", %{persistence_key: key})]}

          {:error, reason} ->
            {final_ctx, dirs} = next.(sig, ctx)

            {final_ctx,
             dirs ++
               [emit("jido.persist.thaw.failed", %{reason: reason, persistence_key: key})]}
        end
    end
  end

  def on_signal(%Signal{type: @stopping_type} = sig, ctx, opts, next) do
    case opts[:storage] do
      nil ->
        next.(sig, ctx)

      storage ->
        agent_module = ctx.agent_module
        key = opts[:persistence_key]

        # Stage runtime cron specs from server state onto the agent before
        # serialization so they survive across hibernate/thaw.
        cron_specs = Map.get(ctx, :cron_specs, %{})
        agent_with_cron = Jido.Scheduler.attach_staged_cron_specs(ctx.agent, cron_specs)
        to_serialize = apply_externalize(agent_with_cron, agent_module)

        case Jido.Persist.hibernate(storage, agent_module, key, to_serialize) do
          :ok ->
            {final_ctx, dirs} = next.(sig, ctx)

            {final_ctx,
             dirs ++
               [emit("jido.persist.hibernate.completed", %{persistence_key: key})]}

          {:error, reason} ->
            {final_ctx, dirs} = next.(sig, ctx)

            {final_ctx,
             dirs ++
               [
                 emit("jido.persist.hibernate.failed", %{
                   reason: reason,
                   persistence_key: key
                 })
               ]}
        end
    end
  end

  def on_signal(sig, ctx, _opts, next), do: next.(sig, ctx)

  defp emit(type, data), do: %Directive.Emit{signal: Signal.new!(type, data)}

  defp apply_externalize(agent, agent_module),
    do: walk_transforms(agent, agent_module, :externalize)

  defp apply_reinstate(agent, agent_module),
    do: walk_transforms(agent, agent_module, :reinstate)

  defp walk_transforms(agent, agent_module, callback) do
    mods = [agent_module | declared_plugin_modules(agent_module)]

    new_state =
      Enum.reduce(mods, agent.state, fn mod, acc ->
        if transform_impl?(mod) and Map.has_key?(acc, mod.path()) do
          Map.update!(acc, mod.path(), &apply(mod, callback, [&1]))
        else
          acc
        end
      end)

    %{agent | state: new_state}
  end

  defp declared_plugin_modules(agent_module) do
    if function_exported?(agent_module, :plugins, 0) do
      agent_module.plugins()
    else
      []
    end
  end

  defp transform_impl?(mod) do
    Code.ensure_loaded(mod)

    function_exported?(mod, :externalize, 1) and
      function_exported?(mod, :reinstate, 1) and
      function_exported?(mod, :path, 0)
  end
end
