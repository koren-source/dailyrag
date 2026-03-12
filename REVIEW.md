# DailyRag End-to-End Code Review — 2026-03-12
Model: Claude Opus 4.6

## Summary

The pipeline architecture is sound — the Phase 1 (scrape all) / Phase 2 (segment rotating 3) split, the segmentation backlog, and the dedup/decay system are well-designed and cleanly implemented in Elixir. However, there are several critical bugs that would cause runtime crashes or incorrect data on the first live run. The two biggest risks are: (1) the **entire discovery pipeline is broken** end-to-end (Python returns raw HTML, Elixir expects parsed brand maps, CaseClauseError on every call), and (2) the **confidence logic has two bugs** that produce wrong values in both initial assignment and upgrades. The `--recover` flag is accepted but does nothing. Several Sheets fields don't match the PDR spec (Entry# format, source_category, brand_source_detail). The segmenter test is dead code that can't actually test the CLI-based segmenter. Fix the 9 critical items below and this is production-ready.

---

## Critical (must fix before first live run)

**1. Discovery pipeline crashes at runtime — `CaseClauseError`**
`lib/dailyrag/scraper.ex:32-41` + `priv/scraper/scrape_ads.py:174`

The Python scraper returns `{"html": "<raw HTML>"}` for discovery mode. In `run_python/2`, `Jason.decode` produces `{:ok, %{"html" => ...}}` which matches none of the three `case` clauses (`is_list`, `%{"error" => msg}`, or `{:error, _}`). This raises `CaseClauseError` every time discovery runs.

Beyond the crash, there's a deeper gap: nobody parses the HTML into brand maps. The PDR says "[ELIXIR] Extract brand names + page URLs from results" — this extraction logic doesn't exist. Discovery needs either: (a) a Claude call to parse the HTML into structured brand data, or (b) regex/DOM parsing in Python that returns the brand list directly.

**Fix:** Add a `{:ok, other} -> {:ok, other}` clause in `run_python` to prevent the crash, then implement the brand extraction logic (either in Python returning a list of brand maps, or in Elixir with a Claude call to parse the HTML).

---

**2. Confidence upgrade logic lets `emerging` skip `curated` and jump to `verified`**
`lib/dailyrag/decay.ex:88-94`

```elixir
cond do
  confidence == "verified" -> "verified"
  age_days >= 30 -> "verified"                           # BUG: catches emerging too
  confidence == "curated" and age_days >= 30 -> "verified"  # DEAD CODE: never reached
  age_days >= 14 and confidence in ["emerging", ""] -> "curated"
  true -> confidence
end
```

The second clause matches ANY non-verified ad at 30+ days, including `emerging`. An `emerging` ad at day 30 jumps directly to `verified`, skipping `curated`. The third clause is dead code (never reached). PDR says: "emerging → curated at 14d, curated → verified at 30d".

**Fix:**
```elixir
cond do
  confidence == "verified" -> "verified"
  confidence == "curated" and age_days >= 30 -> "verified"
  confidence in ["emerging", ""] and age_days >= 14 -> "curated"
  true -> confidence
end
```

---

**3. Initial confidence always "emerging" — ignores ad start_date**
`lib/dailyrag/pipeline/daily.ex:206`

`enrich_segments` hardcodes `"confidence" => "emerging"` for every new ad. PDR says: "Auto-assign confidence: 30+ days = verified, 14-29 = curated, 0-13 = emerging" based on ad runtime (start_date). A brand's first scrape will capture ads that have been running for months — they should be `verified`, not `emerging`.

**Fix:** Calculate initial confidence from `ad["start_date"]` relative to today:
```elixir
defp initial_confidence(start_date_str) do
  case Date.from_iso8601(start_date_str || "") do
    {:ok, start_date} ->
      age = Date.diff(Date.utc_today(), start_date)
      cond do
        age >= 30 -> "verified"
        age >= 14 -> "curated"
        true -> "emerging"
      end
    _ -> "emerging"
  end
end
```

---

**4. `--recover` flag is accepted but completely unimplemented**
`lib/dailyrag/pipeline/daily.ex` (entire file) + `lib/mix/tasks/dailyrag.ex:29`

The mix task parses `--recover` into `opts_map` and passes it to `Daily.run/1`, but `run/1` never reads `opts.recover`. There's no logic to load a checkpoint, skip already-processed brands, or resume from a crash point. `Checkpoint.save!/1` is only used to clear the checkpoint at the end, and `Checkpoint.load/0` is never called in the daily pipeline.

**Fix:** At the start of `run/1`, if `opts.recover` is true, load the checkpoint and skip brands already processed (by index or name). Save checkpoint after each brand completes scraping. On successful completion, clear checkpoint.

---

**5. Entry# format wrong — plain integers instead of SD-XXXX / HD-XXXX**
`lib/dailyrag/sheets/schema.ex:73`

`build_daily_row` produces `Integer.to_string(entry_number)` → plain "1", "2", etc. PDR says: "Sequential ID — SD-XXXX (supplements) or HD-XXXX (home services)".

**Fix:** Pass vertical to `build_daily_row` and format:
```elixir
prefix = if vertical == "dtc-supplements", do: "SD", else: "HD"
"#{prefix}-#{String.pad_leading(Integer.to_string(entry_number), 4, "0")}"
```

---

**6. Source Category is "brand" — PDR says always "ad-library"**
`lib/dailyrag/pipeline/daily.ex:204`

`enrich_segments` sets `"source_category" => "brand"`. PDR column H says: "Source Category — Always `ad-library` (matches master sheet convention)".

**Fix:** Change to `"source_category" => "ad-library"`.

---

**7. Brand/Source Detail missing ad_id — PDR requires "Brand / Lib ID XXXX" format**
`lib/dailyrag/pipeline/daily.ex:209`

`enrich_segments` sets `"brand_source_detail" => brand.brand_name` (just "Ghost"). PDR column J says: "Brand name + Meta Library ID (e.g., 'Ghost / Lib ID 1792148812170796')".

**Fix:**
```elixir
"brand_source_detail" => "#{brand.brand_name} / Lib ID #{segment["source_ad_id"]}"
```

---

**8. Segment Type enum doesn't match PDR spec**
`lib/dailyrag/segmenter.ex:59-63`

The Claude prompt uses creative angle categories ("Problem-Solution", "Social Proof/UGC", "Before/After Transformation", etc.). PDR specifies structural ad segments: `hook`, `body`, `CTA`, `offer`, `social_proof`, `education`, `b_roll_direction`. These are fundamentally different taxonomies — the PDR wants each ad broken into structural parts, the code classifies each ad by its creative angle.

**Fix:** Either update the Claude prompt to use the PDR's segment enum (breaking ads into structural parts), or get explicit sign-off from Koren/Ryan that the creative-angle taxonomy is preferred. If keeping the current approach, update the PDR.

---

**9. Decay sets `last_seen = today` — PDR says yesterday**
`lib/dailyrag/pipeline/daily.ex:268`

When marking inactive ads, `maybe_mark_inactive` sets `last_seen = Util.today()`. PDR says: "update its row → status = 'inactive', last_seen = yesterday's date". The ad was last seen yesterday, not today.

**Fix:**
```elixir
yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()
# ...
%{range: "#{tab}!M#{row_index}", values: [[yesterday]]}
```

---

## Important (fix soon)

**10. `--dry-run` still writes to Sheets via `TabInit.ensure_tabs!`**
`lib/dailyrag/pipeline/daily.ex:15`

`TabInit.ensure_tabs!` creates tabs and overwrites header rows on every run, including dry-run. PDR says dry-run should skip all Sheets writes.

**Fix:** Guard with `unless dry_run, do: TabInit.ensure_tabs!(sheet_id)`.

---

**11. `--brand` flag scrapes ALL brands, not just the specified one**
`lib/dailyrag/pipeline/daily.ex:92`

PDR says `--brand <name>: Run for a single brand only`. The code scrapes all 18 brands and only segments the specified one. This means a "single brand" run still takes 18x the scraping time and updates dedup/decay for all brands.

**Fix:** Filter `active_brands` down to just the specified brand before passing to `scrape_all_brands`.

---

**12. No inter-brand delay in scraping — bot detection risk**
`lib/dailyrag/pipeline/daily.ex:94` (the `Enum.reduce` loop)

PDR says: "Configurable delay between brands (avoid bot detection)". The pipeline loops through all brands with no sleep between scrapes. This risks triggering Meta's bot detection.

**Fix:** Add `Process.sleep(delay)` between brand scrapes (2-5 seconds, configurable via env var).

---

**13. Python scraper has no retry-with-backoff**
`priv/scraper/scrape_ads.py:125-153`

PDR says: "if Scrapling fails → try Playwright fallback → if both fail, retry 2x with backoff". The code does StealthyFetcher → DynamicFetcher with no retry loop or backoff.

**Fix:** Add a retry loop (2 attempts with exponential backoff) wrapping the full StealthyFetcher → DynamicFetcher sequence.

---

**14. Segmenter test is dead code — mocks an HTTP client the segmenter doesn't use**
`test/dailyrag/segmenter_test.exs`

The test creates a `FakeReq` module and sets `:segmenter_http_client` / `:anthropic_api_key` in Application config. But the actual segmenter calls `System.cmd(@claude_bin, ...)` via CLI — it never reads those config values. Running this test would attempt to call the real `claude` binary.

**Fix:** Either rewrite the segmenter to accept an injectable command runner, or rewrite the test to mock `System.cmd` (e.g., via a configurable module attribute or wrapper function).

---

**15. Schema test has 3 incorrect assertions — would fail if run**
`test/dailyrag/sheets/schema_test.exs:9,11,49`

- Line 9: `discovery_keywords_headers` returns 3 items, test expects 4
- Line 11: `daily_report_headers` returns 16 items, test expects 8
- Line 49: `parsed.page_id` — `parse_brand_config_row` doesn't have a `page_id` field (it has `status` at index 3)

**Fix:** Update test assertions to match current schema.

---

**16. `tab_init` overwrites headers on every run**
`lib/dailyrag/sheets/tab_init.ex:18`

`update_range` does a PUT on the header row every run, even if headers haven't changed. This is wasteful API quota and would clobber any manual header edits.

**Fix:** Only write headers when the tab is newly created (move the `update_range` call inside the `unless tab in existing_tabs` block).

---

**17. Goth GenServer is dead code — never started or used**
`lib/goth.ex`

A full GenServer implementation for OAuth token management exists but is never added to the Application supervisor, and `Client` does its own token refresh. Either use Goth or remove it.

**Fix:** Delete `lib/goth.ex` or wire it into `Application` and `Client`.

---

## Minor / Nice-to-have

**18. Slack summary format doesn't match PDR's visual spec**
`lib/dailyrag/slack.ex:13-36`

PDR shows a formatted message with line separators (`━━━━━━━━━━━━━━━━━━━━━━━━━━━━`), "Brands with zero new ads", and "Brands with zero active ads (⚠️ possible scrape issue)". The code outputs a simpler key-value list.

---

**19. Discovery_Queue schema deviates from PDR**
`lib/dailyrag/sheets/schema.ex:37-46`

PDR: brand_name, vertical, meta_library_url, keyword_source, estimated_ad_count, date_found, status.
Code: brand_name, vertical, meta_library_url, page_id, discovered_date, keyword_source, status.
`estimated_ad_count` is replaced by `page_id`; column order differs.

---

**20. Daily_Report has 16 columns vs PDR's 12**
`lib/dailyrag/sheets/schema.ex:49-68`

Code adds 4 useful operational columns (Brands Scraped, Brands Segmented Today, Segmentation Queue, Total Segmented). Not a bug — an improvement — but the PDR should be updated to match.

---

**21. Brand_Config missing `notes` column**
PDR defines 7 columns (including optional `notes`). Code has 6. Harmless but inconsistent.

---

**22. Rotation fragility on brand list changes**
`lib/dailyrag/rotation.ex:46`

Rotation stores an integer index. If brands are added/removed/reordered in Brand_Config, the index may point to a different brand than expected. Some brands could be skipped or double-processed.

**Fix:** Consider rotating by brand name instead of index position.

---

**23. Dry-run dequeues from backlog without re-queuing**
`lib/dailyrag/pipeline/daily.ex:164-167`

In dry-run, `segment_brand` dequeues ads from the backlog and returns `{:ok, length(ads_to_segment), backlog}` — but `backlog` here is the *already-dequeued* version. Since dry-run doesn't save state (line 42-48), this is harmless in practice, but the logged "would segment N ads" count is misleading because it includes the dequeue.

---

**24. `Rotation.load` and `save!` use hardcoded path — not configurable for tests**
`lib/dailyrag/rotation.ex:8`

Unlike Dedup, Decay, and SegmentationBacklog which use `Application.get_env` for path overrides, Rotation uses a module attribute `@rotation_path`. This makes isolated testing harder.

---

## Confirmed Working

- Phase 1 (scrape all brands) + Phase 2 (segment rotating 3) architecture is correct
- Dedup: `filter_new` correctly identifies new ads; atomic save via tmp+rename
- Decay: `diff` correctly computes disappeared/new ad sets
- Rotation: `next_brands` returns correct count, advances index, idempotent same-day
- SegmentationBacklog: enqueue deduplicates, dequeue FIFO, failed segmentation re-enqueues
- Single brand scrape failure continues to next brand (doesn't abort run)
- Sheets API failure records to `failed_writes.json`; retried on next run
- Google Sheets client has proper retry with exponential backoff, 401 auto-refresh
- Seed script has all 18 brands (10 supplements + 8 home services) and 26 discovery keywords
- `.env` is gitignored and not tracked
- Cron setup documented correctly (daily at 6 AM MT, discovery Sundays)
- Atomic write pattern used consistently for all JSON state files
- Claude CLI with `--print` flag and 10-minute timeout is reasonable
- Segmenter JSON parsing strips markdown code fences, validates structure

## Recommendation

**No-Go** for first live run until these are fixed:

1. Fix confidence upgrade logic (items #2, #3) — wrong data in the sheet is worse than no data
2. Fix Entry# format, source_category, brand_source_detail (items #5, #6, #7) — Ryan's downstream ingestion depends on matching the master sheet schema
3. Fix decay `last_seen` date (item #9) — ad lifespan calculations would be off by 1 day
4. Implement `--recover` or remove the flag (item #4)

**Conditional Go** after those 4 are fixed. Items #1 (discovery) and #8 (segment enum) can be deferred since discovery only runs Sundays and the segment taxonomy question needs a product decision.

Run the first live run as `--dry-run --verbose` to validate scraping works, then a real run on a single brand (`--brand "Ghost"`) before the full 18-brand run.
