defmodule ElixirMixir.Behavior do
  @moduledoc """
  Version 1 contract for inactive generated artifacts and later stable process hosts.

  Config, events and state are bounded JSON maps with string keys. Replies must be
  bounded JSON values; effects are bounded JSON maps interpreted by the kernel.
  Callbacks must return data rather than perform effects directly. Every artifact
  exports all four callbacks, even when it retains the same schema on replacement.

  A template is submitted as `defmodule Generated do ... end`; the compiler rewrites
  its outer name to a unique reserved module. Defining it runs only state_schema/0,
  never init/1 or handle_event/2. This contract is not an Elixir sandbox.

  For example, an already compiled implementation can return these transitions:

      iex> state = %{"count" => 0}
      iex> {:ok, state["count"] + 1, Map.update!(state, "count", &(&1 + 1)), []}
      {:ok, 1, %{"count" => 1}, []}
  """

  @doc "Initializes bounded state from JSON config when a worker is started."
  @callback init(map()) :: {:ok, map()} | {:error, term()}

  @doc "Stages a reply, new state and effects for one event; errors retain prior state."
  @callback handle_event(map(), map()) :: {:ok, term(), map(), [map()]} | {:error, term()}

  @doc "Identifies a positive state-schema version; validated under a callback deadline."
  @callback state_schema() :: pos_integer()

  @doc "Migrates state with string-key revision metadata; migration cannot emit effects."
  @callback migrate(map(), map()) :: {:ok, map()} | {:error, term()}
end
