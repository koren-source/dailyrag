defmodule DailyRag.UtilTest do
  use ExUnit.Case, async: true

  alias DailyRag.Util

  test "atomic_write!/2 writes the target file" do
    File.rm_rf!("tmp/util_test")
    path = "tmp/util_test/output.txt"

    assert :ok = Util.atomic_write!(path, "hello")
    assert File.read!(path) == "hello"
  end

  test "ensure_data_dir!/0 creates data directory" do
    File.rm_rf!("tmp/util_data_dir")
    File.mkdir_p!("tmp/util_data_dir")

    cwd = File.cwd!()
    File.cd!("tmp/util_data_dir")

    try do
      assert :ok = Util.ensure_data_dir!()
      assert File.dir?("data")
    after
      File.cd!(cwd)
    end
  end

  test "today and parse_date return ISO-compatible values" do
    assert Util.today() =~ ~r/^\d{4}-\d{2}-\d{2}$/
    assert Util.parse_date("2026-03-12") == ~D[2026-03-12]
  end
end
