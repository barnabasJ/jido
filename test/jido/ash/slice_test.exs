defmodule Jido.Ash.SliceTest do
  use ExUnit.Case, async: true

  alias Jido.Ash.Slice.PayloadField
  alias Jido.Ash.Slice.Info
  alias Jido.Ash.Slice.PersistenceField
  alias Jido.Ash.Slice.SignalEntry
  alias Jido.Ash.Slice.SignalPayload
  alias Jido.Ash.Slice.StateField
  alias Jido.Ash.Slice.Verifiers.SignalActionsExist
  alias Jido.Dsl.Agent.Info, as: AgentInfo
  alias Jido.Dsl.Slice.Info, as: SliceInfo
  alias JidoTest.Ash.DeclaredSliceResource
  alias JidoTest.Ash.CustomPersistenceSliceResource
  alias JidoTest.Ash.CustomPersistenceTransform
  alias JidoTest.Ash.DomainComposedAgentDomain
  alias JidoTest.Ash.PersistenceSliceResource
  alias JidoTest.Ash.PolicySliceResource
  alias JidoTest.Ash.ProvingSliceResource
  alias JidoTest.Ash.ReducerSliceResource
  alias JidoTest.Ash.SignalPayloadSliceResource
  alias JidoTest.Ash.StateSliceResource
  alias JidoTest.Ash.UnsupportedSignalPayloadSliceResource
  alias JidoTest.Ash.UnsupportedStateSliceResource

  @tag story: "US-AJSL-01"
  test "an Ash resource can declare a Jido slice block and signal bindings" do
    # Given an Ash resource using the Jido Ash slice extension
    # When the module declares slice metadata and signal bindings
    # Then the resource compiles and exposes the declaration for later generation
    assert Spark.Dsl.is?(DeclaredSliceResource, Ash.Resource)
    assert Info.name(DeclaredSliceResource) == "event_loop"

    assert [
             %SignalEntry{type: "event.start", action: :start},
             %SignalEntry{type: "event.cancel", action: :cancel}
           ] = Info.signals(DeclaredSliceResource)
  end

  @tag story: "US-AJSL-05"
  test "Info exposes metadata and generated action modules" do
    # Given an Ash-backed slice resource with metadata and signal bindings
    # When a developer calls the Info accessors
    # Then they receive stable declaration data and generated action module metadata
    assert Info.description(DeclaredSliceResource) == "Event loop slice"
    assert Info.category(DeclaredSliceResource) == "reasoning"
    assert Info.vsn(DeclaredSliceResource) == "0.1.0"
    assert Info.otp_app(DeclaredSliceResource) == :jido
    assert Info.tags(DeclaredSliceResource) == ["agent", "reasoning"]

    assert [
             %SignalEntry{type: "event.start", action: :start},
             %SignalEntry{type: "event.cancel", action: :cancel}
           ] = Info.signals(DeclaredSliceResource)

    assert Info.generated_slice_module(DeclaredSliceResource) ==
             JidoTest.Ash.DeclaredSliceResource.Jido.Slice

    assert [
             JidoTest.Ash.DeclaredSliceResource.Jido.Start,
             JidoTest.Ash.DeclaredSliceResource.Jido.Cancel
           ] = Info.generated_action_modules(DeclaredSliceResource)
  end

  @tag story: "US-AJSL-07"
  test "Info derives a slice state schema from Ash attributes" do
    # Given an Ash-backed slice resource with typed attributes
    # When a developer asks for state fields and the derived state schema
    # Then attributes, defaults, docs, and public metadata are represented
    assert [
             %StateField{
               name: :title,
               type: Ash.Type.String,
               allow_nil?: false,
               public?: true,
               default: :none,
               description: "Visible title"
             },
             %StateField{name: :attempts, type: Ash.Type.Integer, default: {:static, 0}},
             %StateField{name: :active, type: Ash.Type.Boolean, default: {:static, true}},
             %StateField{name: :tags, type: {:array, Ash.Type.String}, default: {:static, []}},
             %StateField{name: :metadata, type: Ash.Type.Map, allow_nil?: true, public?: false}
           ] = Info.state_fields(StateSliceResource)

    schema = Info.state_schema(StateSliceResource)

    assert {:ok, %{title: "run", attempts: 0, active: true, tags: [], metadata: nil}} =
             Zoi.parse(schema, %{title: "run"})

    assert {:ok, %{title: "run", metadata: nil, attempts: 0, active: true, tags: []}} =
             Zoi.parse(schema, %{title: "run", metadata: nil})

    assert {:error, [%Zoi.Error{code: :required, path: [:title]}]} = Zoi.parse(schema, %{})
  end

  @tag story: "US-AJSL-08"
  test "unsupported Ash attribute types fail clearly" do
    # Given an Ash-backed slice resource with an unsupported state type
    # When a developer asks for the derived state schema
    # Then the error names the unsupported Ash type instead of silently using any
    assert_raise ArgumentError,
                 ~r/unsupported Ash-backed slice state attribute type Ash.Type.Binary/,
                 fn ->
                   Info.state_schema(UnsupportedStateSliceResource)
                 end
  end

  @tag story: "US-AJSL-20"
  test "Info exposes generated persistence metadata for Ash attributes" do
    # Given an Ash-backed slice resource with durable, transient, and restored fields
    # When a developer inspects persistence metadata
    # Then each state attribute has a stable checkpoint mode
    assert [
             %PersistenceField{name: :durable_count, mode: :durable, default: {:static, 0}},
             %PersistenceField{name: :durable_note, mode: :durable, default: :none},
             %PersistenceField{name: :transient_buffer, mode: :transient, default: {:static, []}},
             %PersistenceField{name: :restored_buffer, mode: :restored, default: {:static, []}}
           ] = Info.persistence_fields(PersistenceSliceResource)
  end

  @tag story: "US-AJSL-21"
  test "generated slice persistence transform excludes and restores attributes by metadata" do
    # Given a generated Ash-backed slice module with persistence metadata
    # When checkpoint externalize and thaw reinstate run through the generated callbacks
    # Then durable fields survive, transient fields are dropped, and restored fields reset
    slice_module = Info.generated_slice_module(PersistenceSliceResource)

    runtime_state = %{
      durable_count: 7,
      durable_note: nil,
      transient_buffer: ["drop me"],
      restored_buffer: ["runtime only"]
    }

    Code.ensure_loaded!(slice_module)

    assert function_exported?(slice_module, :externalize, 1)
    assert function_exported?(slice_module, :reinstate, 1)

    assert %{durable_count: 7, durable_note: nil} = slice_module.externalize(runtime_state)

    assert %{durable_count: 7, durable_note: nil, restored_buffer: []} =
             slice_module.reinstate(%{durable_count: 7, durable_note: nil})
  end

  @tag story: "US-AJSL-24"
  test "generated slice delegates checkpoint callbacks to the declared custom transform" do
    # Given an Ash-backed slice declaring application-specific checkpoint encoding
    slice_module = Info.generated_slice_module(CustomPersistenceSliceResource)

    # When the generated persistence callbacks run
    assert Info.persistence_transform(CustomPersistenceSliceResource) ==
             CustomPersistenceTransform

    assert %{encoded: "durable"} = slice_module.externalize(%{value: "durable"})

    # Then both directions delegate to the declared transform
    assert %{value: "durable", restored_by: CustomPersistenceTransform} =
             slice_module.reinstate(%{encoded: "durable"})
  end

  @tag story: "US-AJSL-09"
  test "Info derives signal payload schemas from Ash action inputs" do
    # Given an Ash-backed slice with signal bindings to an action and an update
    # When a developer inspects signal payloads and schemas
    # Then action arguments and accepted attributes appear in stable payload shape
    assert [
             %SignalPayload{
               type: "event.record",
               action: :record,
               fields: [
                 %PayloadField{name: :reason, source: :argument, allow_nil?: false},
                 %PayloadField{name: :urgent, source: :argument, default: {:static, false}}
               ]
             },
             %SignalPayload{
               type: "event.rename",
               action: :rename,
               fields: [
                 %PayloadField{name: :title, source: :attribute, allow_nil?: false},
                 %PayloadField{name: :attempts, source: :attribute, default: {:static, 0}}
               ]
             }
           ] = Info.signal_payloads(SignalPayloadSliceResource)

    record_schema = Info.signal_payload_schema(SignalPayloadSliceResource, "event.record")

    assert {:ok, %{reason: "because", urgent: false}} =
             Zoi.parse(record_schema, %{reason: "because"})

    assert {:error, [%Zoi.Error{code: :required, path: [:reason]}]} =
             Zoi.parse(record_schema, %{})

    rename_schema = Info.signal_payload_schema(SignalPayloadSliceResource, "event.rename")
    assert {:ok, %{title: "next", attempts: 0}} = Zoi.parse(rename_schema, %{title: "next"})

    assert_raise ArgumentError,
                 ~r/unsupported Ash-backed slice payload field type Ash.Type.Binary/,
                 fn ->
                   Info.signal_payload_schema(
                     UnsupportedSignalPayloadSliceResource,
                     "event.record"
                   )
                 end
  end

  @tag story: "US-AJSL-10"
  test "missing signal target actions fail at compile time" do
    # Given an Ash-backed slice signal that references a missing action
    # When the verifier checks the resource's signal declarations
    # Then the verifier reports the missing target action clearly
    dsl_state = %{
      [:jido_slice] => %{entities: [%SignalEntry{type: "event.missing", action: :missing}]},
      persist: %{module: DeclaredSliceResource}
    }

    assert {:error,
            %Spark.Error.DslError{
              message:
                "jido_slice signal \"event.missing\" references missing Ash action :missing",
              path: [:jido_slice, :signal]
            }} = SignalActionsExist.verify(dsl_state)
  end

  @tag story: "US-AJSL-11"
  test "Info exposes stable generated reducer action modules" do
    # Given an Ash-backed slice resource with generic reducer actions
    # When the resource compiles through the Jido Ash slice extension
    # Then generated Jido action modules are stable and introspectable
    assert [
             JidoTest.Ash.ReducerSliceResource.Jido.Increment,
             JidoTest.Ash.ReducerSliceResource.Jido.Fail
           ] = Info.generated_action_modules(ReducerSliceResource)

    assert Info.generated_action_module(ReducerSliceResource, :increment) ==
             JidoTest.Ash.ReducerSliceResource.Jido.Increment

    assert Jido.Dsl.Action.Info.name(JidoTest.Ash.ReducerSliceResource.Jido.Increment) ==
             "counter_increment"
  end

  @tag story: "US-AJSL-12"
  test "generated reducer actions return next slice state and directives" do
    # Given a generated Jido action for an Ash reducer action
    # When the action runs with signal payload and current slice state
    # Then the Ash result is adapted to {:ok, next_slice, directives}
    signal = Jido.Signal.new!(%{type: "counter.increment", source: "/test", data: %{amount: 3}})

    assert {:ok, %{count: 5}, [%Jido.Directives.Emit{signal: emitted}]} =
             JidoTest.Ash.ReducerSliceResource.Jido.Increment.run(signal, %{count: 2}, %{}, %{})

    assert emitted.type == "counter.incremented"
    assert emitted.data == %{count: 5}
  end

  @tag story: "US-AJSL-13"
  test "generated reducer actions preserve error results without state mutation" do
    # Given a generated Jido action for an Ash reducer action that fails
    # When the action returns an error-shaped reducer result
    # Then the generated action returns {:error, reason} and no replacement slice
    signal = Jido.Signal.new!(%{type: "counter.fail", source: "/test", data: %{reason: "boom"}})

    assert {:error, {:reducer_failed, "boom"}} =
             JidoTest.Ash.ReducerSliceResource.Jido.Fail.run(signal, %{count: 2}, %{}, %{})
  end

  @tag story: "US-AJSL-14"
  test "generated Ash-backed slice module exposes state schema and routes" do
    # Given an Ash-backed slice resource with state and generated reducer actions
    # When a developer inspects its generated Jido slice module
    # Then the module is mountable and exposes schema, routes, and action targets
    slice_module = Info.generated_slice_module(ReducerSliceResource)

    assert slice_module == JidoTest.Ash.ReducerSliceResource.Jido.Slice
    assert Spark.Dsl.is?(slice_module, Jido.Slice)
    assert SliceInfo.name(slice_module) == "counter"

    assert {:ok, %{count: 0}} = Zoi.parse(SliceInfo.schema(slice_module), %{})

    assert [
             {"counter.increment", JidoTest.Ash.ReducerSliceResource.Jido.Increment},
             {"counter.increment.alternate", JidoTest.Ash.ReducerSliceResource.Jido.Increment},
             {"counter.fail", JidoTest.Ash.ReducerSliceResource.Jido.Fail}
           ] = SliceInfo.signal_routes(slice_module)

    assert SliceInfo.actions(slice_module) == [
             JidoTest.Ash.ReducerSliceResource.Jido.Increment,
             JidoTest.Ash.ReducerSliceResource.Jido.Fail
           ]
  end

  @tag story: "US-AJSL-15"
  test "hand-authored Jido slices keep their existing Info surfaces" do
    # Given existing hand-authored Jido slices
    # When Ash-backed slice modules are generated elsewhere
    # Then existing slice introspection still reads the hand-authored DSL
    assert Spark.Dsl.is?(Jido.Slices.Thread, Jido.Slice)
    assert SliceInfo.name(Jido.Slices.Thread) == "thread"
    assert [_ | _] = SliceInfo.signal_routes(Jido.Slices.Thread)
  end

  @tag story: "US-AJSL-16"
  test "Jido.Agent mounts Ash-backed slice resources at agent-owned paths" do
    # Given an agent that mounts an Ash-backed resource and a hand-authored slice
    # When the agent compiles and seeds initial state
    # Then the Ash resource resolves to its generated slice at the agent-owned path
    defmodule MixedAshSliceAgent do
      use Jido.Agent, default_slices: false

      agent do
        name "mixed_ash_slice_agent"
      end

      slices do
        slice(:counter_one, ReducerSliceResource)
        slice(:conversation, Jido.Slices.Thread)
      end
    end

    assert [
             %{module: JidoTest.Ash.ReducerSliceResource.Jido.Slice, path: :counter_one},
             %{module: Jido.Slices.Thread, path: :conversation}
           ] = AgentInfo.slice_instances(MixedAshSliceAgent)

    agent = MixedAshSliceAgent.new(state: %{counter_one: %{count: 7}})

    assert agent.state.counter_one == %{count: 7}
    assert Map.has_key?(agent.state, :conversation)
  end

  @tag story: "US-AJSL-17"
  test "Ash-backed slice mounts expand routes to generated reducer actions" do
    # Given an agent mounting an Ash-backed slice resource
    # When the agent route table is expanded
    # Then generated reducer actions are routed from the resource-backed mount
    defmodule AshSliceRouteAgent do
      use Jido.Agent, default_slices: false

      agent do
        name "ash_slice_route_agent"
      end

      slices do
        slice(:counter_two, ReducerSliceResource)
      end
    end

    assert {"counter.increment", JidoTest.Ash.ReducerSliceResource.Jido.Increment, -10} in AgentInfo.routes(
             AshSliceRouteAgent
           )

    assert AgentInfo.slice_paths_for_action(AshSliceRouteAgent)[
             JidoTest.Ash.ReducerSliceResource.Jido.Increment
           ] == [:counter_two]
  end

  @tag story: "US-AJAC-01"
  test "Ash domains expose Jido agent composition metadata" do
    # Given an Ash domain declaring Jido agent metadata and an Ash-backed slice mount
    # When a developer inspects the domain-backed composition
    # Then identity, explicit mount paths, routes, and action ownership are available
    assert Jido.Ash.Domain.Info.name(DomainComposedAgentDomain) == "domain_composed_agent"

    assert Jido.Ash.Domain.Info.description(DomainComposedAgentDomain) ==
             "Domain-backed agent composition"

    assert [
             %{module: JidoTest.Ash.ReducerSliceResource.Jido.Slice, path: :counter_mount}
           ] = Jido.Ash.Domain.Info.slice_instances(DomainComposedAgentDomain)

    assert {"counter.increment", JidoTest.Ash.ReducerSliceResource.Jido.Increment, -10} in Jido.Ash.Domain.Info.routes(
             DomainComposedAgentDomain
           )

    assert Jido.Ash.Domain.Info.slice_paths_for_action(DomainComposedAgentDomain)[
             JidoTest.Ash.ReducerSliceResource.Jido.Increment
           ] == [:counter_mount]
  end

  @tag story: "US-AJAC-02"
  test "domain-backed composition matches a simple hand-authored Jido agent" do
    # Given a hand-authored Jido agent and a domain composition with the same slice mount
    # When their composition metadata is inspected
    # Then the generated domain metadata matches the existing agent baseline
    defmodule DomainCompositionBaselineAgent do
      use Jido.Agent, default_slices: false

      agent do
        name "domain_composed_agent"
        description "Domain-backed agent composition"
      end

      slices do
        slice(:counter_mount, ReducerSliceResource)
      end
    end

    assert Jido.Ash.Domain.Info.name(DomainComposedAgentDomain) ==
             AgentInfo.name(DomainCompositionBaselineAgent)

    assert Jido.Ash.Domain.Info.slice_instances(DomainComposedAgentDomain) ==
             AgentInfo.slice_instances(DomainCompositionBaselineAgent)

    assert Jido.Ash.Domain.Info.routes(DomainComposedAgentDomain) ==
             AgentInfo.routes(DomainCompositionBaselineAgent)

    assert Jido.Ash.Domain.Info.slice_paths_for_action(DomainComposedAgentDomain) ==
             AgentInfo.slice_paths_for_action(DomainCompositionBaselineAgent)
  end

  @tag story: "US-AJSL-22"
  test "mounted proving slice handles a signal through the generated reducer" do
    # Given a tiny Ash-backed slice mounted in a Jido agent
    # When the agent runs the generated action with the original input signal
    # Then state updates through the mounted slice and directives are returned
    defmodule ProvingSliceAgent do
      use Jido.Agent, default_slices: false

      agent do
        name "proving_slice_agent"
      end

      slices do
        slice(:proving, ProvingSliceResource)
      end
    end

    agent = ProvingSliceAgent.new(state: %{proving: %{count: 2}})

    assert Info.generated_slice_module(ProvingSliceResource) ==
             JidoTest.Ash.ProvingSliceResource.Jido.Slice

    assert Info.generated_action_module(ProvingSliceResource, :add) ==
             JidoTest.Ash.ProvingSliceResource.Jido.Add

    assert {:ok, %{count: 0}} = Zoi.parse(Info.state_schema(ProvingSliceResource), %{})

    assert [
             %{module: JidoTest.Ash.ProvingSliceResource.Jido.Slice, path: :proving}
           ] = AgentInfo.slice_instances(ProvingSliceAgent)

    signal =
      Jido.Signal.new!(%{
        type: "proving.add",
        source: "/test",
        data: %{amount: 4, lifecycle_metadata: "ignored"}
      })

    assert {"proving.add", JidoTest.Ash.ProvingSliceResource.Jido.Add, -10} in AgentInfo.routes(
             ProvingSliceAgent
           )

    assert {:ok, updated_agent, [%Jido.Directives.Emit{signal: emitted}]} =
             ProvingSliceAgent.cmd(
               agent,
               {JidoTest.Ash.ProvingSliceResource.Jido.Add, %{amount: 4}},
               input_signal: signal,
               ctx: proving_policy_ctx(:operator)
             )

    assert updated_agent.state.proving == %{count: 6}
    assert emitted.type == "proving.counted"
    assert emitted.data == %{count: 6}
  end

  @tag story: "US-AJSL-23"
  test "mounted proving slice policy denial prevents state updates" do
    # Given a tiny Ash-backed slice mounted in a Jido agent
    # When the generated reducer is denied by Ash policy checks
    # Then cmd returns a structured error and leaves the original agent unchanged
    defmodule ProvingSliceDeniedAgent do
      use Jido.Agent, default_slices: false

      agent do
        name "proving_slice_denied_agent"
      end

      slices do
        slice(:proving, ProvingSliceResource)
      end
    end

    agent = ProvingSliceDeniedAgent.new(state: %{proving: %{count: 2}})

    signal =
      Jido.Signal.new!(%{
        type: "proving.add",
        source: "/test",
        data: %{amount: 4}
      })

    assert {:error, %Jido.Error.ExecutionError{details: %{reason: %Ash.Error.Forbidden{}}}} =
             ProvingSliceDeniedAgent.cmd(
               agent,
               {JidoTest.Ash.ProvingSliceResource.Jido.Add, %{amount: 4}},
               input_signal: signal,
               ctx: proving_policy_ctx(:viewer)
             )

    assert agent.state.proving == %{count: 2}
  end

  @tag story: "US-AJSL-18"
  test "generated reducers run with runtime actor context and tenant" do
    # Given an Ash-backed reducer protected by Ash policies
    # When the generated action runs with runtime actor, context, and tenant data
    # Then Ash authorizes the reducer and the action sees the same runtime data
    signal =
      Jido.Signal.new!(%{
        type: "policy_counter.increment",
        source: "/test",
        data: %{amount: 2}
      })

    ctx = %{
      actor: %{role: :operator},
      context: %{allow_slice_transition?: true, request_id: "req-1"},
      tenant: "tenant-a"
    }

    refute Keyword.has_key?(
             Jido.Ash.Slice.ReducerAdapter.ash_opts(%{}, %{}, %{}, %{}),
             :authorize?
           )

    assert {:ok,
            %{
              count: 5,
              actor_role: :operator,
              request_id: "req-1",
              tenant: "tenant-a"
            }, []} =
             PolicySliceResource.Jido.SecureIncrement.run(
               signal,
               %{count: 3},
               %{authorize?: true},
               ctx
             )
  end

  @tag story: "US-AJSL-19"
  test "generated reducers preserve structured Ash policy denial errors" do
    # Given an Ash-backed reducer protected by Ash policies
    # When the generated action runs with authorization enabled and a forbidden actor
    # Then the reducer returns Ash's structured policy denial without mutating state
    signal =
      Jido.Signal.new!(%{
        type: "policy_counter.increment",
        source: "/test",
        data: %{amount: 2}
      })

    ctx = %{
      actor: %{role: :viewer},
      context: %{allow_slice_transition?: true, request_id: "req-2"},
      tenant: "tenant-a"
    }

    assert {:error, %Ash.Error.Forbidden{}} =
             PolicySliceResource.Jido.SecureIncrement.run(
               signal,
               %{count: 3},
               %{authorize?: true},
               ctx
             )
  end

  defp proving_policy_ctx(role) do
    %{
      actor: %{role: role},
      context: %{allow_slice_transition?: true},
      tenant: "tenant-a"
    }
  end
end
