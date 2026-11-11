defmodule ElixirMixir.Runtime.Replacement do
  @moduledoc "Stages compatible state retention or bounded explicit schema migration inside the existing host."

  alias ElixirMixir.Runtime.Callback
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.ResponseBudget

  @doc "Checks the current worker revision and preflights the complete candidate transition before host commit."
  @spec stage(map(), map(), pos_integer(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def stage(host, artifact, expected, context) do
    if host.worker_revision == expected do
      with {:ok, data, migration} <- migrate(host, artifact, context) do
        preflight(host, artifact, data, migration, context)
      end
    else
      {:error, Error.new("REVISION_CONFLICT")}
    end
  end

  defp migrate(%{artifact: %{state_schema: schema}} = host, %{state_schema: schema}, _context),
    do: {:ok, host.data, "preserved"}

  defp migrate(host, artifact, context) do
    metadata = %{
      "worker_id" => host.worker_id,
      "old_artifact_id" => host.artifact.id,
      "new_artifact_id" => artifact.id,
      "old_state_schema" => host.artifact.state_schema,
      "new_state_schema" => artifact.state_schema,
      "worker_revision" => host.worker_revision,
      "state_revision" => host.state_revision,
      "request_id" => context.request_id
    }

    with {:ok, {:ok, data}} <-
           Callback.run(fn -> artifact.module.migrate(host.data, metadata) end, host.limits),
         :ok <- ProcessHost.valid_state(data, host.limits) do
      {:ok, data, "migrated"}
    else
      {:error, error} -> migration_error(error)
      {:ok, _malformed} -> migration_error(Error.new("INVALID_TRANSITION"))
    end
  end

  defp preflight(host, artifact, data, migration, context) do
    state_revision = host.state_revision + if(migration == "migrated", do: 1, else: 0)

    result = %{
      "worker_id" => host.worker_id,
      "artifact_id" => artifact.id,
      "previous_revision" => host.artifact.revision,
      "new_revision" => artifact.revision,
      "worker_revision" => host.worker_revision + 1,
      "state_revision" => state_revision,
      "migration_result" => migration,
      "pid_before" => inspect(self()),
      "pid_after" => inspect(self())
    }

    envelope =
      Map.merge(result, %{
        "api_version" => "1",
        "generation" => context.generation,
        "request_id" => context.request_id
      })

    if ResponseBudget.fits?(envelope, host.limits) do
      next = %{
        host
        | artifact: artifact,
          data: data,
          worker_revision: host.worker_revision + 1,
          state_revision: state_revision
      }

      {:ok, result, next}
    else
      {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp migration_error(error) do
    details = Map.put(error["details"], "cause", error["code"])
    {:error, Map.put(Error.new("MIGRATION_FAILED"), "details", details)}
  end
end
