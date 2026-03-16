defmodule AeroVision.DBTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "aerovision_db_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # ──────────────────────────────────────────────── happy path ──

  describe "open/1 happy path" do
    test "returns a pid", %{dir: dir} do
      pid = AeroVision.DB.open(data_dir: dir)
      assert is_pid(pid)
    end

    test "returned pid is alive", %{dir: dir} do
      pid = AeroVision.DB.open(data_dir: dir)
      assert Process.alive?(pid)
    end

    test "returned pid is a working CubDB instance", %{dir: dir} do
      pid = AeroVision.DB.open(data_dir: dir)
      :ok = CubDB.put(pid, :hello, "world")
      assert CubDB.get(pid, :hello) == "world"
    end
  end

  # ──────────────────────────────────────────────── corrupt recovery ──

  describe "open/1 corrupt database recovery" do
    test "returns a working pid even when database file is corrupt", %{dir: dir} do
      # Write garbage bytes to the data file CubDB would normally open
      corrupt_file = Path.join(dir, "0.cub")
      File.write!(corrupt_file, "garbage bytes that are not valid CubDB format !@#$%")

      pid = AeroVision.DB.open(data_dir: dir)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "recovered database is empty (CubDB.size == 0)", %{dir: dir} do
      corrupt_file = Path.join(dir, "0.cub")
      File.write!(corrupt_file, "garbage bytes that are not valid CubDB format !@#$%")

      pid = AeroVision.DB.open(data_dir: dir)
      assert CubDB.size(pid) == 0
    end

    test "recovered database accepts writes and reads", %{dir: dir} do
      corrupt_file = Path.join(dir, "0.cub")
      File.write!(corrupt_file, "garbage bytes that are not valid CubDB format !@#$%")

      pid = AeroVision.DB.open(data_dir: dir)
      :ok = CubDB.put(pid, :key, "value")
      assert CubDB.get(pid, :key) == "value"
    end
  end

  # ──────────────────────────────────────────────── trap_exit restored ──

  describe "open/1 trap_exit flag" do
    test "restores trap_exit to original false after successful open", %{dir: dir} do
      original = Process.flag(:trap_exit, false)

      _pid = AeroVision.DB.open(data_dir: dir)

      {:trap_exit, restored} = Process.info(self(), :trap_exit)
      # Put back whatever it was before this test
      Process.flag(:trap_exit, original)

      assert restored == false
    end

    test "restores trap_exit to original true after successful open", %{dir: dir} do
      original = Process.flag(:trap_exit, true)

      _pid = AeroVision.DB.open(data_dir: dir)

      {:trap_exit, restored} = Process.info(self(), :trap_exit)
      Process.flag(:trap_exit, original)

      assert restored == true
    end

    test "restores trap_exit to false after corrupt recovery", %{dir: dir} do
      Process.flag(:trap_exit, false)
      corrupt_file = Path.join(dir, "0.cub")
      File.write!(corrupt_file, "garbage bytes that are not valid CubDB format !@#$%")

      _pid = AeroVision.DB.open(data_dir: dir)

      {:trap_exit, restored} = Process.info(self(), :trap_exit)
      assert restored == false
    end
  end

  # ──────────────────────────────────────────────── already_started ──

  describe "open/1 already_started" do
    test "second call with same name returns the pid of the first", %{dir: dir} do
      name = :"test_db_#{System.unique_integer([:positive])}"
      pid1 = AeroVision.DB.open(data_dir: dir, name: name)
      pid2 = AeroVision.DB.open(data_dir: dir, name: name)
      assert pid1 == pid2
    end

    test "returned already-started pid is still alive", %{dir: dir} do
      name = :"test_db_#{System.unique_integer([:positive])}"
      pid1 = AeroVision.DB.open(data_dir: dir, name: name)
      pid2 = AeroVision.DB.open(data_dir: dir, name: name)
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end
end
