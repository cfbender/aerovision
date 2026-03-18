defmodule AeroVision.Cache do
  @moduledoc """
  Persistent key-value cache backed by CubDB with optional ETS read-through.

  Designed to be started as multiple named instances, each with its own CubDB
  database and optional ETS table. Handles:

  - **Persistence** — durable storage via CubDB, with automatic corruption
    recovery via `AeroVision.DB`.
  - **Fast reads** — optional ETS read-through layer for concurrent access
    without GenServer bottleneck.
  - **TTL expiration** — optional time-based expiration of entries.
  - **Periodic pruning** — optional background cleanup of expired entries.
  - **Cache versioning** — automatic data migration when the version bumps.

  ## Start Options

      {AeroVision.Cache,
        name: :flight_cache,           # required — GenServer name + ETS table name
        data_dir: "skylink_cache",     # required — directory name (resolved to full path)
        cache_version: 2,              # default 1 — bump to invalidate on deploy
        ets: true,                     # default false — enable ETS read-through
        ttl: 86_400,                   # default nil — TTL in seconds (requires ets: true)
        prune_interval: 86_400_000,    # default nil — prune timer in ms
        cubdb_opts: []}                # default [] — extra opts for CubDB

  ## Usage

      Cache.get(:flight_cache, "DAL1209")
      Cache.put(:flight_cache, "DAL1209", flight_info)
      Cache.delete(:flight_cache, "DAL1209")
  """

  use GenServer

  require Logger

  # ─────────────────────────────────────────────────────────── public API ──

  @doc "Start a cache instance. See module docs for options."
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Read a value by key. Returns `{value, cached_at}` or `nil`.

  When ETS is enabled, reads bypass the GenServer for maximum throughput.
  """
  def get(name, key) do
    case ets_table(name) do
      nil ->
        GenServer.call(name, {:get, key})

      table ->
        case :ets.lookup(table, key) do
          [{^key, value, cached_at}] -> {value, cached_at}
          _ -> nil
        end
    end
  end

  @doc "Write a value. Stores in both ETS (if enabled) and CubDB."
  def put(name, key, value) do
    GenServer.call(name, {:put, key, value})
  end

  @doc "Delete a key from both ETS and CubDB."
  def delete(name, key) do
    GenServer.call(name, {:delete, key})
  end

  @doc """
  Evict a key from ETS only, preserving the CubDB entry as crash-recovery
  fallback. Used for re-enrichment flows where we want to bypass the cache
  check but keep persistence.
  """
  def evict(name, key) do
    GenServer.call(name, {:evict, key})
  end

  @doc """
  Clear all data keys from both ETS and CubDB. Preserves system keys
  like `:cache_version`.
  """
  def clear(name) do
    GenServer.call(name, :clear)
  end

  # ───────────────────────────────────────────────────────────── callbacks ──

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    data_dir_name = Keyword.fetch!(opts, :data_dir)
    cache_version = Keyword.get(opts, :cache_version, 1)
    ets_enabled = Keyword.get(opts, :ets, false)
    ttl = Keyword.get(opts, :ttl)
    prune_interval = Keyword.get(opts, :prune_interval)
    cubdb_opts = Keyword.get(opts, :cubdb_opts, [])

    # Resolve data directory
    data_dir = resolve_data_dir(data_dir_name)
    File.mkdir_p!(data_dir)

    # Open CubDB — use name-based registration only for non-test instances
    # (test instances pass unique data_dir_name values and should stay anonymous)
    cubdb_name = :"#{name}_cubdb"

    db_opts =
      [data_dir: data_dir] ++
        cubdb_opts ++
        if(production_name?(data_dir_name), do: [name: cubdb_name], else: [])

    db = AeroVision.DB.open(db_opts)

    # Optionally create ETS table
    ets_table =
      if ets_enabled do
        table = ets_table_name(name)

        if :ets.whereis(table) == :undefined do
          :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
        else
          :ets.delete_all_objects(table)
        end

        table
      end

    # Run cache version migration
    stored_version = CubDB.get(db, :cache_version, 0)

    if stored_version < cache_version do
      Logger.info("[Cache:#{name}] Version #{stored_version} < #{cache_version} — clearing stale data")

      if ets_table, do: :ets.delete_all_objects(ets_table)

      data_keys =
        db
        |> CubDB.select()
        |> Enum.filter(fn {key, _} -> data_key?(key) end)
        |> Enum.map(fn {key, _} -> key end)

      if data_keys != [], do: CubDB.delete_multi(db, data_keys)
      CubDB.put(db, :cache_version, cache_version)
    else
      # Hydrate ETS from CubDB on startup
      if ets_table do
        now = System.system_time(:second)

        db
        |> CubDB.select()
        |> Enum.each(fn
          {key, {value, cached_at}} when not is_atom(key) ->
            if is_nil(ttl) or now - cached_at < ttl do
              :ets.insert(ets_table, {key, value, cached_at})
            else
              CubDB.delete(db, key)
            end

          _ ->
            :ok
        end)
      end
    end

    # Schedule pruning if configured
    if prune_interval do
      schedule_prune(prune_interval)
    end

    state = %{
      name: name,
      db: db,
      ets_table: ets_table,
      ttl: ttl,
      prune_interval: prune_interval
    }

    # Store ETS table reference in persistent_term for fast access in get/2
    if ets_table do
      :persistent_term.put({__MODULE__, name, :ets_table}, ets_table)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    result =
      case CubDB.get(state.db, key) do
        {value, cached_at} when is_integer(cached_at) -> {value, cached_at}
        nil -> nil
        # Legacy data stored before the Cache module was introduced —
        # wrap it with cached_at=0 so TTL checks treat it as old data.
        legacy_value -> {legacy_value, 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    now = System.system_time(:second)
    CubDB.put(state.db, key, {value, now})

    if state.ets_table do
      :ets.insert(state.ets_table, {key, value, now})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    CubDB.delete(state.db, key)

    if state.ets_table do
      :ets.delete(state.ets_table, key)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:evict, key}, _from, state) do
    if state.ets_table do
      :ets.delete(state.ets_table, key)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    if state.ets_table do
      :ets.delete_all_objects(state.ets_table)
    end

    data_keys =
      state.db
      |> CubDB.select()
      |> Enum.filter(fn {key, _} -> data_key?(key) end)
      |> Enum.map(fn {key, _} -> key end)

    if data_keys != [], do: CubDB.delete_multi(state.db, data_keys)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:prune, state) do
    prune(state)

    if state.prune_interval do
      schedule_prune(state.prune_interval)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ─────────────────────────────────────────────────────────── internals ──

  defp prune(%{ttl: nil}), do: :ok

  defp prune(%{db: db, ets_table: ets_table, ttl: ttl, name: name}) do
    now = System.system_time(:second)

    expired_keys =
      db
      |> CubDB.select()
      |> Stream.filter(fn
        {key, {_value, cached_at}} when not is_atom(key) -> now - cached_at >= ttl
        _ -> false
      end)
      |> Enum.map(fn {key, _} -> key end)

    if expired_keys != [] do
      CubDB.delete_multi(db, expired_keys)
      CubDB.compact(db)

      if ets_table do
        Enum.each(expired_keys, &:ets.delete(ets_table, &1))
      end

      Logger.debug("[Cache:#{name}] Pruned #{length(expired_keys)} expired entries")
    end
  end

  defp schedule_prune(interval) do
    Process.send_after(self(), :prune, interval)
  end

  # Data keys are anything that's not an atom (system keys like :cache_version are atoms)
  defp data_key?(key) when is_atom(key), do: false
  defp data_key?(_key), do: true

  # Look up the ETS table for a named cache instance (fast path via persistent_term)
  defp ets_table(name) do
    :persistent_term.get({__MODULE__, name, :ets_table}, nil)
  end

  defp ets_table_name(name), do: :"#{name}_ets"

  # Resolve a data directory name to a full path based on the target environment.
  defp resolve_data_dir(data_dir_name) do
    # If it looks like an absolute path (e.g., from tests), use it directly
    if String.starts_with?(data_dir_name, "/") do
      data_dir_name
    else
      case Application.get_env(:aerovision, :target, :host) do
        target when target in [:host, :test] ->
          Path.join(System.user_home!(), ".aerovision/#{data_dir_name}")

        _ ->
          "/data/aerovision/#{data_dir_name}"
      end
    end
  end

  # Named instances use well-known directory names; test instances use tmp paths.
  defp production_name?(data_dir_name) do
    not String.starts_with?(data_dir_name, "/")
  end
end
