#!/usr/bin/env elixir

# Usage:
#
#   mix run scripts/verify_livemd.exs guides/slices.livemd
#
# Extracts every ```elixir block from the livemd and evaluates each in order,
# threading the binding so later cells see modules / vars from earlier cells.
# Any cell that raises stops the run and prints which cell index failed.
#
# This is a "demo doesn't blow up at compile time" smoke check, not a unit
# test. The user-facing `IO.inspect` output goes to stderr/stdout as usual.

defmodule LivemdVerifier do
  def run([path]) when is_binary(path) do
    cells = path |> File.read!() |> extract_cells()
    IO.puts("verifying #{path} — #{length(cells)} elixir cells")

    Enum.reduce(cells, [], fn {idx, code}, binding ->
      IO.puts("\n=== cell #{idx} ===")
      IO.puts(snippet(code))

      cond do
        String.contains?(code, "Mix.install") ->
          IO.puts("(skipping Mix.install — runs only in fresh Livebook session)")
          binding

        true ->
          try do
            # Strip the calling module from the eval env so `defmodule Foo` lands
            # at top-level, not nested under LivemdVerifier.
            env = %{__ENV__ | module: nil, function: nil}
            {_value, new_binding} = Code.eval_string(code, binding, env)
            new_binding
          rescue
            e ->
              IO.puts(:stderr, "\n!! cell #{idx} raised:")
              IO.puts(:stderr, Exception.format(:error, e, __STACKTRACE__))
              System.halt(1)
          end
      end
    end)

    IO.puts("\nOK — all cells evaluated without raising")
  end

  defp extract_cells(content) do
    content
    |> String.split("\n")
    |> collect_cells([], nil, 0, [])
    |> Enum.with_index(1)
    |> Enum.map(fn {code, idx} -> {idx, code} end)
  end

  defp collect_cells([], cells, nil, _, _), do: Enum.reverse(cells)

  defp collect_cells([line | rest], cells, nil, idx, _) do
    case String.trim(line) do
      "```elixir" -> collect_cells(rest, cells, [], idx + 1, [])
      _ -> collect_cells(rest, cells, nil, idx, [])
    end
  end

  defp collect_cells([line | rest], cells, current, idx, _) do
    case String.trim(line) do
      "```" ->
        code = current |> Enum.reverse() |> Enum.join("\n")
        collect_cells(rest, [code | cells], nil, idx, [])

      _ ->
        collect_cells(rest, cells, [line | current], idx, [])
    end
  end

  defp snippet(code) do
    code
    |> String.split("\n")
    |> Enum.take(3)
    |> Enum.join("\n")
    |> Kernel.<>("\n... (#{length(String.split(code, "\n"))} lines)")
  end
end

System.argv() |> LivemdVerifier.run()
