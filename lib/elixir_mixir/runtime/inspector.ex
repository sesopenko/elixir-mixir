defmodule ElixirMixir.Runtime.Inspector do
  @moduledoc "Read-only generation-bound worker/topology pages and bounded event history without generated callbacks."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Workers

  @doc "Reads actual worker state or a sorted worker/edge page, visibly omitting fields to fit the wire budget."
  @spec inspect_runtime(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def inspect_runtime(%{"worker_id" => id} = args, state) do
    with {:ok, worker} <- Workers.find(state.workers, id) do
      data = worker_snapshot(worker, Map.get(args, "detail", "summary"), state)
      fit_worker(data, state)
    end
  end

  def inspect_runtime(args, state) do
    stats = EffectDispatcher.snapshot(state.dispatcher, self())
    workers = Enum.sort_by(state.workers, &elem(&1, 0))
    edges = topology(stats, state.workers)
    detail = Map.get(args, "detail", "summary")

    with {:ok, worker_offset, edge_offset} <-
           position(args, state, detail, length(workers), length(edges)) do
      limit = Map.get(args, "limit", state.limits.page_default)

      page =
        workers
        |> Enum.drop(worker_offset)
        |> Enum.take(limit)
        |> Enum.map(fn {_id, worker} -> worker_snapshot(worker, detail, state) end)

      graph = edges |> Enum.drop(edge_offset) |> Enum.take(limit)

      base = %{
        "health" => "ok",
        "recovery" =>
          Map.merge(state.recovery, %{
            "boot_id" => state.boot_id,
            "lineage_id" => state.lineage_id
          }),
        "storage" => %{
          "mode" => Atom.to_string(state.storage.mode),
          "format_version" => if(state.storage.mode == :durable, do: 1, else: nil)
        },
        "worker_count" => length(workers),
        "edge_count" => length(edges),
        "limits" => Map.new(state.limits, fn {key, value} -> {Atom.to_string(key), value} end),
        "ledger" => %{
          "capacity" => state.limits.ledger_entries,
          "retention_ms" => state.limits.ledger_retention_ms
        },
        "effects" => Map.take(stats, ["pending", "timers", "reserved"])
      }

      paging = %{
        workers: length(workers),
        edges: length(edges),
        worker_offset: worker_offset,
        edge_offset: edge_offset,
        detail: detail
      }

      fit_page(base, page, graph, paging, state)
    end
  end

  @doc "Reads a filtered history page with exclusive cursor, eviction gaps and visible response-size omissions."
  @spec events(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def events(args, state) do
    with :ok <- known_worker(args, state) do
      page = EventLog.events(args, state.event_log)
      fit_events(page, state)
    end
  end

  defp worker_snapshot(worker, detail, state) do
    snapshot = Workers.snapshot(worker, detail, state.limits)
    {:ok, artifact} = ArtifactRegistry.fetch(worker.artifact.id)

    metadata =
      Map.take(artifact, [
        :id,
        :logical_name,
        :revision,
        :state_schema,
        :source_hash,
        :contract_version
      ])

    metadata = Map.new(metadata, fn {key, value} -> {Atom.to_string(key), value} end)
    Map.put(snapshot, "artifact", metadata)
  end

  defp fit_worker(data, state) do
    cond do
      fits?(data, state) -> {:ok, data}
      Map.has_key?(data, "artifact") -> fit_worker(omit(data, "artifact"), state)
      Map.has_key?(data, "state") -> fit_worker(omit(data, "state"), state)
      true -> {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp fit_page(base, workers, edges, paging, state) do
    data = page_data(base, workers, edges, paging, state)

    cond do
      fits?(data, state) ->
        {:ok, data}

      Map.has_key?(base, "limits") ->
        fit_page(omit(base, "limits"), workers, edges, paging, state)

      Enum.any?(workers, &Map.has_key?(&1, "artifact")) ->
        fit_page(base, Enum.map(workers, &omit_if_present(&1, "artifact")), edges, paging, state)

      Enum.any?(workers, &Map.has_key?(&1, "state")) ->
        fit_page(base, Enum.map(workers, &omit_if_present(&1, "state")), edges, paging, state)

      length(workers) + length(edges) > 1 ->
        shrink_page(base, workers, edges, paging, state)

      true ->
        {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp page_data(base, workers, edges, paging, state) do
    worker_offset = paging.worker_offset + length(workers)
    edge_offset = paging.edge_offset + length(edges)
    more = worker_offset < paging.workers or edge_offset < paging.edges
    cursor = if more, do: cursor(state, worker_offset, edge_offset, paging.detail), else: nil

    Map.merge(base, %{
      "workers" => workers,
      "topology" => edges,
      "next_cursor" => cursor,
      "truncated" => more or Map.get(base, "truncated", false)
    })
  end

  defp shrink_page(base, workers, edges, paging, state) do
    if length(workers) >= length(edges),
      do: fit_page(base, Enum.drop(workers, -1), edges, paging, state),
      else: fit_page(base, workers, Enum.drop(edges, -1), paging, state)
  end

  defp fit_events(page, state) do
    records = page["events"]

    cond do
      fits?(page, state) ->
        {:ok, page}

      length(records) > 1 ->
        records = Enum.drop(records, -1)
        next = List.last(records)["sequence"]

        fit_events(
          Map.merge(page, %{"events" => records, "next_cursor" => next, "page_truncated" => true}),
          state
        )

      Enum.any?(records, &Map.has_key?(&1, "metadata")) ->
        records = Enum.map(records, &omit_if_present(&1, "metadata"))
        fit_events(Map.merge(page, %{"events" => records, "page_truncated" => true}), state)

      true ->
        {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp known_worker(%{"worker_id" => id}, state) do
    case Workers.find(state.workers, id) do
      {:ok, _worker} -> :ok
      error -> error
    end
  end

  defp known_worker(_args, _state), do: :ok

  defp position(%{"cursor" => encoded}, state, detail, workers, edges) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, ["1", runtime, generation, worker_offset, edge_offset, ^detail]} <-
           Jason.decode(json),
         true <- runtime == state.inspection_id and generation == state.generation,
         true <- is_integer(worker_offset) and worker_offset >= 0 and worker_offset <= workers,
         true <- is_integer(edge_offset) and edge_offset >= 0 and edge_offset <= edges do
      {:ok, worker_offset, edge_offset}
    else
      _invalid ->
        {:error,
         Map.put(Error.new("INVALID_ARGUMENT"), "details", %{
           "hint" => "Restart pagination without cursor."
         })}
    end
  end

  defp position(_args, _state, _detail, _workers, _edges), do: {:ok, 0, 0}

  defp cursor(state, workers, edges, detail),
    do:
      ["1", state.inspection_id, state.generation, workers, edges, detail]
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

  defp topology(stats, workers) do
    delivered =
      Map.new(stats["topology"], fn edge -> {{edge["from"], edge["to"]}, edge["count"]} end)

    pending =
      Map.new(stats["pending_edges"], fn edge -> {{edge["from"], edge["to"]}, edge["pending"]} end)

    (Map.keys(delivered) ++ Map.keys(pending))
    |> Enum.uniq()
    |> Enum.filter(fn {source, target} ->
      Map.has_key?(workers, source) and Map.has_key?(workers, target)
    end)
    |> Enum.sort()
    |> Enum.map(fn {source, target} = key ->
      %{
        "from" => source,
        "to" => target,
        "count" => Map.get(delivered, key, 0),
        "pending" => Map.get(pending, key, 0)
      }
    end)
  end

  defp omit_if_present(data, key),
    do: if(Map.has_key?(data, key), do: omit(data, key), else: data)

  defp omit(data, key),
    do: data |> Map.delete(key) |> Map.put(key <> "_omitted", true) |> Map.put("truncated", true)

  defp fits?(data, state),
    do:
      ResponseBudget.fits?(
        Map.merge(data, %{"api_version" => "1", "generation" => state.generation}),
        state.limits
      )
end
