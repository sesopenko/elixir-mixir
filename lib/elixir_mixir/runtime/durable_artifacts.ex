defmodule ElixirMixir.Runtime.DurableArtifacts do
  @moduledoc "Serializes retained artifact metadata and deterministically recompiles valid source into fixed slots."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Compiler
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Values

  @doc "Builds the bounded JSON artifact record, retaining original module identity as a string."
  @spec record(map()) :: map()
  def record(artifact) do
    %{
      "source" => artifact.source,
      "source_hash" => artifact.source_hash,
      "logical_name" => artifact.logical_name,
      "revision" => artifact.revision,
      "contract_version" => artifact.contract_version,
      "state_schema" => artifact.state_schema,
      "original_module" => Atom.to_string(artifact.module),
      "diagnostics" => artifact.diagnostics,
      "compiler_helpers" => artifact.compiler_helpers
    }
  end

  @doc "Restores IDs in sorted order, retaining bounded diagnostics for invalid definitions."
  @spec recover(map(), Limits.t()) :: {:ok, map()} | {:error, Error.t()}
  def recover(records, limits) do
    artifacts = for {{:artifact, id}, record} <- records, do: {id, record}

    if length(artifacts) + ArtifactRegistry.status()["attempts"] <= limits.artifact_slots do
      :ok = ArtifactRegistry.seed_revisions(revisions(artifacts))

      outcomes =
        artifacts
        |> Enum.sort()
        |> Enum.map(fn {id, record} -> {id, restore(id, record, limits)} end)

      failures =
        for {id, {:error, error}} <- outcomes, do: %{"artifact_id" => id, "code" => error["code"]}

      {:ok,
       %{
         "artifacts" => length(artifacts),
         "restored" => length(artifacts) - length(failures),
         "quarantined" => length(failures),
         "degraded" => failures != [],
         "diagnostics" => Enum.take(failures, limits.diagnostics)
       }}
    else
      {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp restore(id, record, limits) do
    with :ok <- validate(id, record, limits),
         {:ok, reservation} <- ArtifactRegistry.reserve(limits.artifact_slots),
         {:ok, compiled} <- Compiler.compile(record["source"], reservation, limits),
         true <- compiled.state_schema == record["state_schema"] do
      artifact =
        Map.merge(compiled, %{
          id: id,
          source: record["source"],
          source_hash: record["source_hash"],
          logical_name: record["logical_name"],
          revision: record["revision"],
          contract_version: record["contract_version"],
          original_module: record["original_module"]
        })

      ArtifactRegistry.restore(reservation, artifact)
    else
      false -> {:error, Error.new("INVALID_ARGUMENT")}
      error -> error
    end
  end

  defp validate(id, record, limits) when is_map(record) do
    with :ok <-
           Values.validate(record, :reply, %{
             limits
             | reply_bytes: limits.source_bytes * 6 + limits.metadata_bytes
           }),
         true <-
           is_binary(record["original_module"]) and is_integer(record["state_schema"]) and
             record["state_schema"] > 0,
         true <- Values.valid_id?(id) and Values.valid_id?(record["logical_name"]),
         true <- is_integer(record["revision"]) and record["revision"] > 0,
         true <- record["contract_version"] == "elixir_mixir.behavior.v1",
         :ok <- Values.validate(record["source"], :source, limits),
         true <-
           record["source_hash"] ==
             Base.encode16(:crypto.hash(:sha256, record["source"]), case: :lower) do
      :ok
    else
      _invalid -> {:error, Error.new("INVALID_ARGUMENT")}
    end
  end

  defp validate(_id, _record, _limits), do: {:error, Error.new("INVALID_ARGUMENT")}

  defp revisions(artifacts) do
    Enum.reduce(artifacts, %{}, fn {_id, record}, acc ->
      if is_map(record) and Values.valid_id?(record["logical_name"]) and
           is_integer(record["revision"]) and record["revision"] > 0 do
        Map.update(acc, record["logical_name"], record["revision"], &max(&1, record["revision"]))
      else
        acc
      end
    end)
  end
end
