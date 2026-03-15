defmodule AeroVision.Config.StoreTest do
  use ExUnit.Case, async: false

  setup do
    # Use a temp dir for each test
    tmp_dir = Path.join(System.tmp_dir!(), "aerovision_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  # Tests will be added as the store is implemented
  test "placeholder" do
    assert true
  end
end
