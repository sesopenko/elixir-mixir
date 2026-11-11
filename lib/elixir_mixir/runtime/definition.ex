defmodule ElixirMixir.Runtime.Definition do
  @moduledoc "Stages and commits a generated artifact after bounded compilation and response preflight."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Compiler
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Values

  @keys ~w(logical_name source expected_behavior request_id)

  @doc "Validates definition metadata and raw source bytes before consuming a slot."
  @spec validate(map(), Limits.t()) :: :ok | {:error, Error.t()}
  def validate(args, limits) do
    if Enum.sort(Map.keys(args)) == Enum.sort(@keys) and Values.valid_id?(args["logical_name"]) and
         args["expected_behavior"] == "elixir_mixir.behavior.v1" do
      Values.validate(args["source"], :source, limits)
    else
      {:error, Error.new("INVALID_ARGUMENT")}
    end
  end

  @doc "Defines one inactive artifact; only success publishes metadata and advances logical revision."
  @spec define(map(), non_neg_integer(), Limits.t()) :: {:ok, map()} | {:error, Error.t()}
  def define(args, generation, limits) do
    outcome =
      with :ok <- validate(args, limits),
           {:ok, reservation} <- ArtifactRegistry.reserve(limits.artifact_slots),
           {:ok, compiled} <- Compiler.compile(args["source"], reservation, limits) do
        stage(args, generation, reservation, compiled, limits)
      end

    record(args, outcome)
    outcome
  end

  defp stage(args, generation, reservation, compiled, limits) do
    hash = :crypto.hash(:sha256, args["source"]) |> Base.encode16(case: :lower)

    artifact =
      Map.merge(compiled, %{
        id: "artifact_#{reservation.slot}_#{hash}",
        source: args["source"],
        source_hash: hash,
        logical_name: args["logical_name"],
        contract_version: "elixir_mixir.behavior.v1",
        revision: ArtifactRegistry.next_revision(args["logical_name"])
      })

    data = %{
      "artifact_id" => artifact.id,
      "module" => Atom.to_string(artifact.module),
      "source_hash" => hash,
      "revision" => artifact.revision,
      "state_schema" => artifact.state_schema,
      "compilation_status" => "compiled",
      "diagnostics" => artifact.diagnostics,
      "callbacks_valid" => true
    }

    envelope =
      Map.merge(data, %{
        "api_version" => "1",
        "generation" => generation,
        "request_id" => args["request_id"]
      })

    if ResponseBudget.fits?(envelope, limits) do
      :ok = ArtifactRegistry.register(reservation, artifact)
      {:ok, data}
    else
      {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp record(args, {status, data}) do
    EventLog.append(%{
      "type" => if(status == :ok, do: "compile_succeeded", else: "compile_failed"),
      "logical_id" =>
        if(Values.valid_id?(args["logical_name"]), do: args["logical_name"], else: nil),
      "worker_id" => nil,
      "artifact_revision" => data["revision"],
      "request_id" => args["request_id"],
      "outcome" => if(status == :ok, do: "ok", else: data["code"]),
      "metadata" => Map.take(data, ["artifact_id", "source_hash"])
    })
  end
end
