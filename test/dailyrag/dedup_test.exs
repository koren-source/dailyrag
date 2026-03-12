defmodule DailyRag.DedupTest do
  use ExUnit.Case, async: false

  alias DailyRag.Dedup

  setup do
    File.rm_rf!("tmp/dedup_test")
    File.mkdir_p!("tmp/dedup_test")
    cwd = File.cwd!()
    File.cd!("tmp/dedup_test")
    on_exit(fn -> File.cd!(cwd) end)
    :ok
  end

  test "load from missing file returns empty index" do
    assert Dedup.load() == %{"version" => 1, "ads" => %{}}
  end

  test "add known and filter_new work" do
    index = Dedup.add(Dedup.load(), "AG1", ["123"])

    assert Dedup.known?(index, "123")

    assert [%{"ad_id" => "456"}] =
             Dedup.filter_new(index, [%{"ad_id" => "123"}, %{"ad_id" => "456"}])
  end

  test "save! and load roundtrip" do
    index = Dedup.add(Dedup.load(), "AG1", ["123", "456"])
    assert :ok = Dedup.save!(index)
    assert Dedup.load()["ads"]["123"]["brand"] == "AG1"
  end
end
