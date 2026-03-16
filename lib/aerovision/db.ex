defmodule AeroVision.DB do
  @moduledoc """
  Helper for opening CubDB databases with automatic corruption recovery.

  CubDB files can become corrupt if the device loses power mid-write. When
  this happens, `CubDB.start_link` raises `ArgumentError: invalid external
  representation of a term`. This module catches that error, wipes the
  database directory, and retries — trading data loss for a clean restart
  rather than a crash loop.
  """

  require Logger

  @doc """
  Start a CubDB instance with automatic recovery on corruption.

  Options are passed directly to `CubDB.start_link/1`. If the database
  files are corrupt, the directory is wiped and a fresh database is created.
  Returns the pid on success.

  CubDB raises `ArgumentError` inside its own `init/1` when the file is
  corrupt. Because `start_link` spawns a linked process, the error arrives
  as an EXIT signal rather than a raised exception in our process. We
  temporarily trap exits to intercept it cleanly.
  """
  @spec open(keyword()) :: pid()
  def open(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)

    # Temporarily trap exits so we can catch the crash from CubDB's child
    # process if the database file is corrupt.
    old_trap = Process.flag(:trap_exit, true)

    result =
      case CubDB.start_link(opts) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, reason} ->
          {:corrupt, reason}
      end

    # Drain any EXIT message that may have arrived
    receive do
      {:EXIT, _, _} -> :ok
    after
      0 -> :ok
    end

    # Restore previous trap_exit setting
    Process.flag(:trap_exit, old_trap)

    case result do
      {:ok, pid} ->
        pid

      {:corrupt, reason} ->
        Logger.error(
          "[DB] CubDB failed to open #{data_dir}: #{inspect(reason)}. " <>
            "Wiping and recreating."
        )

        wipe_and_retry(data_dir, opts)
    end
  end

  defp wipe_and_retry(data_dir, opts) do
    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    case CubDB.start_link(opts) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
