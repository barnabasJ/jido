defmodule Jido.AI.Turn do
  @moduledoc """
  Normalized projection of a `ReqLLM.Response`.

  Classifies the response as either a tool-calling turn (the model wants
  the host to run one or more tools and call back) or a final-answer turn
  (the model is done). Consumed by `Jido.AI.Actions.LLMTurn` after
  `Jido.AI.Directive.LLMCall`'s executor packages a `ReqLLM.Response`.

  `ReqLLM.Response.classify/1` does the heavy lifting — finish-reason
  normalization, tool-call extraction, and text/thinking split. This
  module is the thin Jido-side projection that the LLMTurn action consumes.
  """

  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Response

  @type response_type :: :tool_calls | :final_answer
  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}

  @type t :: %__MODULE__{
          type: response_type(),
          text: String.t(),
          thinking_content: String.t() | nil,
          reasoning_details: [ReasoningDetails.t()] | nil,
          tool_calls: [tool_call()],
          usage: map() | nil,
          model: String.t() | nil,
          finish_reason: atom() | nil,
          message_metadata: map()
        }

  defstruct type: :final_answer,
            text: "",
            thinking_content: nil,
            reasoning_details: nil,
            tool_calls: [],
            usage: nil,
            model: nil,
            finish_reason: nil,
            message_metadata: %{}

  @doc """
  Builds a turn from a `ReqLLM.Response` (or passes through an existing
  `Turn`, optionally overriding the model).

  ## Options

    * `:model` — Override the model string from the response.
  """
  @spec from_response(Response.t() | t(), keyword()) :: t()
  def from_response(response, opts \\ [])

  def from_response(%__MODULE__{} = turn, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} -> %{turn | model: model}
      :error -> turn
    end
  end

  def from_response(%Response{} = response, opts) do
    classified = Response.classify(response)

    %__MODULE__{
      type: classified.type,
      text: classified.text,
      thinking_content: empty_to_nil(classified.thinking),
      reasoning_details: reasoning_details(response.message),
      tool_calls: classified.tool_calls,
      usage: Response.usage(response),
      model: Keyword.get(opts, :model, response.model),
      finish_reason: classified.finish_reason,
      message_metadata: message_metadata(response.message)
    }
  end

  @doc """
  Returns true when the turn is requesting tool execution.
  """
  @spec needs_tools?(t()) :: boolean()
  def needs_tools?(%__MODULE__{type: :tool_calls, tool_calls: [_ | _]}), do: true
  def needs_tools?(%__MODULE__{}), do: false

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value) when is_binary(value), do: value

  defp message_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp message_metadata(_), do: %{}

  defp reasoning_details(%{reasoning_details: [_ | _] = details}), do: details
  defp reasoning_details(_), do: nil
end
