defmodule ElixirMixir.Runtime.Transition do
  @moduledoc "Stages complete event outcomes and preflights their wire encoding before host state changes."

  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Effects
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Values

  @doc "Validates reply/state, reserves a complete effect batch and preflights its accepted IDs before commit."
  @spec stage(term(), map(), map()) ::
          {:ok, map(), map(), reference() | :none} | {:error, Error.t()}
  def stage({:ok, reply, data, effects}, host, context) do
    with :ok <- valid_reply(reply, host.limits),
         :ok <- ProcessHost.valid_state(data, host.limits),
         :ok <- supported_effects(effects, context, host.limits),
         {:ok, token, accepted} <-
           EffectDispatcher.reserve_batch(host.dispatcher, effects, context, host.limits) do
      outcome = %{
        "reply" => reply,
        "worker_revision" => host.worker_revision,
        "state_revision" => host.state_revision + 1,
        "effects" => accepted
      }

      envelope =
        Map.merge(outcome, %{
          "api_version" => "1",
          "generation" => context.generation,
          "request_id" => context.request_id
        })

      if ResponseBudget.fits?(envelope, host.limits) do
        {:ok, outcome, %{host | data: data, state_revision: host.state_revision + 1}, token}
      else
        EffectDispatcher.release(host.dispatcher, token)
        {:error, Error.new("LIMIT_EXCEEDED")}
      end
    end
  end

  def stage(_invalid, _host, _context), do: {:error, Error.new("INVALID_TRANSITION")}

  defp supported_effects([], _context, _limits), do: :ok

  defp supported_effects(effects, %{effect_mode: :reject}, limits) do
    with :ok <- Effects.validate(effects, limits),
         do: {:error, Error.new("DURABILITY_UNAVAILABLE")}
  end

  defp supported_effects(_effects, _context, _limits), do: :ok

  defp valid_reply(reply, limits) do
    case Values.validate(reply, :reply, limits) do
      {:error, %{"code" => "INVALID_ARGUMENT"}} -> {:error, Error.new("INVALID_TRANSITION")}
      result -> result
    end
  end
end
