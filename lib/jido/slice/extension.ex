defmodule Jido.Slice.Extension do
  @moduledoc """
  Opt a slice into being a host-agent extension that contributes one
  typed DSL block (`<host_section> do … end`) to host modules that
  list it in `extensions: [...]`.

      defmodule MyApp.MemorySlice do
        use Jido.Slice
        slice do … end
        signal_routes do … end

        use Jido.Slice.Extension, host_section: :memory
      end

  After this, host agents that list `MyApp.MemorySlice` in their
  `extensions:` keyword get a `memory do … end` block whose schema
  is derived from the slice's `config_schema/0` plus a built-in
  `path:` field that lets the host rename the slice's mount path
  inline.

  ## How it works

  The `__using__` macro defines three accessors on the slice:

    * `__jido_host_section__/0` — the section atom (`:memory`).
    * `__jido_host_contribution__/0` — returns the
      `%Spark.Dsl.Section{}` to surface on the host. Computed lazily
      from `Jido.Dsl.Slice.Info.path/1` and the slice's
      `config_schema/0`. Overridable for slices with richer Zoi
      shapes that the translator can't handle.
    * `__jido_host_extension_module__/0` — the sibling
      `Spark.Dsl.Extension` module (`<Slice>.HostExtension`)
      generated alongside the slice via `@after_compile`. Host
      agents inject this module into their `extensions:` list so
      Spark imports the contributed section's macros.

  The shadow extension module is created once, after the slice has
  fully compiled (so the slice's DSL state is queryable), via
  `Module.create/3`.
  """

  alias Jido.Dsl.Slice.Info, as: SliceInfo
  alias Jido.Slice.Extension.SchemaTranslate

  defmacro __using__(opts) do
    section_name = Keyword.fetch!(opts, :host_section)

    quote bind_quoted: [section_name: section_name] do
      @doc false
      @spec __jido_host_section__() :: atom()
      def __jido_host_section__, do: unquote(section_name)

      @doc false
      @spec __jido_host_contribution__() :: Spark.Dsl.Section.t()
      def __jido_host_contribution__ do
        Jido.Slice.Extension.build_section(__MODULE__, unquote(section_name))
      end

      @doc false
      @spec __jido_host_extension_module__() :: module()
      def __jido_host_extension_module__, do: Module.concat(__MODULE__, HostExtension)

      defoverridable __jido_host_contribution__: 0

      @after_compile {Jido.Slice.Extension, :__after_compile__}
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    module = env.module
    shadow = Module.concat(module, HostExtension)
    section = module.__jido_host_contribution__()

    body =
      quote do
        @moduledoc false
        use Spark.Dsl.Extension, sections: [unquote(Macro.escape(section))]
      end

    Module.create(shadow, body, file: env.file, line: env.line)
    :ok
  end

  @doc """
  Builds the `%Spark.Dsl.Section{}` that the host agent surfaces for
  this slice. Reads the slice's `path/0` for the `path:` field
  default and translates `config_schema/0` (when present) for the
  remaining schema entries.
  """
  @spec build_section(module(), atom()) :: Spark.Dsl.Section.t()
  def build_section(module, section_name) do
    %Spark.Dsl.Section{
      name: section_name,
      describe: section_describe(module),
      schema: build_schema(module)
    }
  end

  defp build_schema(module) do
    SchemaTranslate.translate(SliceInfo.config_schema(module))
  end

  defp section_describe(module) do
    SliceInfo.description(module) ||
      "Configuration block contributed by #{inspect(module)}."
  end
end
