defmodule DailyRag.CheckpointTest do
  use ExUnit.Case, async: false

  alias DailyRag.Checkpoint

  setup do
    File.rm_rf!("tmp/checkpoint_test")
    File.mkdir_p!("tmp/checkpoint_test")
    cwd = File.cwd!()
    File.cd!("tmp/checkpoint_test")
    on_exit(fn -> File.cd!(cwd) end)
    :ok
  end

  test "save/load/clear roundtrip" do
    assert :ok = Checkpoint.save!(%{"current_brand_index" => 1})
    assert Checkpoint.load()["current_brand_index"] == 1
    assert :ok = Checkpoint.clear!()
    assert Checkpoint.load() == nil
  end

  test "record_failed_write accumulates entries" do
    assert :ok = Checkpoint.record_failed_write!(%{"type" => "append"})
    assert :ok = Checkpoint.record_failed_write!(%{"type" => "batch"})

    assert [%{"type" => "append"}, %{"type" => "batch"}] =
             Enum.map(Checkpoint.pending_writes(), &Map.take(&1, ["type"]))
  end
end
