defmodule DailyRag.SegmenterTest do
  use ExUnit.Case, async: false

  setup do
    File.rm_rf!("tmp/segmenter_test")
    File.mkdir_p!("tmp/segmenter_test")

    fake_claude = Path.expand("tmp/segmenter_test/fake_claude.sh")

    File.write!(
      fake_claude,
      """
      #!/bin/sh
      printf '%s' '[{"segment_type":"Problem-Solution","principle":"Specific principle","transcript":"Transcript","why_it_works":"Because it is specific","format":"video","source_ad_id":"abc"}]'
      """
    )

    File.chmod!(fake_claude, 0o755)
    Application.put_env(:dailyrag, :claude_bin, fake_claude)

    on_exit(fn ->
      Application.delete_env(:dailyrag, :claude_bin)
    end)

    :ok
  end

  test "segment_ads parses validated response content" do
    ads = [%{"ad_id" => "abc", "copy" => "Example copy", "headline" => "Headline"}]

    assert {:ok, [segment]} = DailyRag.Segmenter.segment_ads("AG1", "supplements", ads)
    assert segment["segment_type"] == "Problem-Solution"
    assert segment["source_ad_id"] == "abc"
  end
end
