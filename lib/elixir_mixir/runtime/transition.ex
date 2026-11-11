defmodule ElixirMixir.Runtime.Transition do
  @moduledoc "Stages complete event outcomes and preflights their wire encoding before host state changes."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Values

  @doc "Validates reply/state and empty effects; returns a staged immutable host state on success only."
  @spec stage(term(), map(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def stage({:ok, reply, data, []}, host, context) do
    with :ok <- valid_reply(reply, host.limits),
         :ok <- ProcessHost.valid_state(data, host.limits) do
      outcome = %{
        "reply" => reply,
        "worker_revision" => host.worker_revision,
        "state_revision" => host.state_revision + 1,
        "effects" => []
      }

      envelope =
        Map.merge(outcome, %{
          "api_version" => "1",
          "generation" => context.generation,
          "request_id" => context.request_id
        })

      if ResponseBudget.fits?(envelope, host.limits) do
        {:ok, outcome, %{host | data: data, state_revision: host.state_revision + 1}}
      else
        {:error, Error.new("LIMIT_EXCEEDED")}
      end
    end
  end

  def stage(_invalid, _host, _context), do: {:error, Error.new("INVALID_TRANSITION")}

  defp valid_reply(reply, limits) do
    case Values.validate(reply, :reply, limits) do
      {:error, %{"code" => "INVALID_ARGUMENT"}} -> {:error, Error.new("INVALID_TRANSITION")}
      result -> result
    end
  end
end
