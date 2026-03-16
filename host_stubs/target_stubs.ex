defmodule Circuits.GPIO do
  @moduledoc "Stub for Circuits.GPIO — satisfies compiler in test/host envs where the dep is unavailable."

  # Functions return opaque types via apply/3 so the compiler cannot infer a
  # specific return type and won't warn about unreachable branches in callers.
  def open(pin, direction, opts \\ []),
    do: apply(__MODULE__, :_open, [pin, direction, opts])

  def set_interrupts(gpio, trigger),
    do: apply(__MODULE__, :_set_interrupts, [gpio, trigger])

  def close(_gpio), do: :ok
  def read(_gpio), do: {:ok, 0}
  def write(_gpio, _value), do: :ok

  # "Private" implementations — never called directly, only via apply/3
  def _open(_pin, _direction, _opts), do: {:ok, make_ref()}
  def _set_interrupts(_gpio, _trigger), do: :ok
end

defmodule VintageNet do
  @moduledoc "Stub for VintageNet — satisfies compiler in test/host envs."
  def configure(_interface, _config), do: :ok
  def subscribe(_property), do: :ok
  def get(_property), do: nil
  def get_configuration(_interface), do: nil
  def scan(_interface), do: []
  def unsubscribe(_property), do: :ok
end

defmodule Nerves.Runtime do
  @moduledoc "Stub for Nerves.Runtime — satisfies compiler in test/host envs."
  def reboot, do: :ok
  def poweroff, do: :ok
end

defmodule Nerves.Runtime.KV do
  @moduledoc "Stub for Nerves.Runtime.KV — satisfies compiler in test/host envs."
  def get_active(_key), do: nil
  def get_all_active, do: %{}
end
