defmodule DailyRag.SegmenterTest do
  use ExUnit.Case, async: false

  defmodule FakeReq do
    def post(_url, _opts) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "content" => [
             %{
               "text" =>
                 ~s([{"segment_type":"Problem-Solution","principle":"Specific principle","transcript":"Transcript","why_it_works":"Because it is specific","format":"video","source_ad_id":"abc"}])
             }
           ]
         }
       }}
    end
  end

  setup do
    Application.put_env(:dailyrag, :anthropic_api_key, "test-key")
    Application.put_env(:dailyrag, :segmenter_http_client, FakeReq)

    on_exit(fn ->
      Application.delete_env(:dailyrag, :segmenter_http_client)
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
