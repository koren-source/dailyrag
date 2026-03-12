# DailyRag Pipeline — Fix Ticket for Codex 5.4

You are working on the `dailyrag` Elixir project at `~/Projects/dailyrag`. This is a daily Meta Ad Library scraping and segmentation pipeline. A code review found bugs that must be fixed before the first live run. Fix all items below in order. After all fixes, run `mix compile --warnings-as-errors` and `mix test` to confirm nothing is broken. Post progress to `#rag-builder`.

---

## PHASE 1 — Fix all 7 items. Do not run the pipeline live until these are done.

### 1. Fix confidence upgrade logic in `lib/dailyrag/decay.ex`

Lines 88-94 have a bug: the `age_days >= 30` clause catches `emerging` ads and promotes them directly to `verified`, skipping `curated`. The third clause is dead code that never executes.

Replace the entire cond block with:

```elixir
cond do
  confidence == "verified" -> "verified"
  confidence == "curated" and age_days >= 30 -> "verified"
  confidence in ["emerging", ""] and age_days >= 14 -> "curated"
  true -> confidence
end
```

The rule is: emerging → curated at 14 days, curated → verified at 30 days. No tier is ever skipped. Confidence never downgrades.

### 2. Fix initial confidence assignment in `lib/dailyrag/pipeline/daily.ex`

In the `enrich_segments` function around line 206, confidence is hardcoded to `"emerging"` for every new ad. This is wrong — when a brand is first scraped, it will have ads that have been running for months. Those must be assigned `verified` or `curated` based on their `start_date`.

Add this private function to the module:

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

Then replace the hardcoded `"confidence" => "emerging"` with `"confidence" => initial_confidence(ad["start_date"])`, passing the ad's start_date from the scraper output.

### 3. Fix Entry# format in `lib/dailyrag/sheets/schema.ex`

In `build_daily_row` around line 73, entry numbers are formatted as plain integers (`"1"`, `"2"`). Change this to use the prefix format:

```elixir
prefix = if vertical == "dtc-supplements", do: "SD", else: "HD"
entry_str = "#{prefix}-#{String.pad_leading(Integer.to_string(entry_number), 4, "0")}"
```

This produces `"SD-0001"`, `"HD-0001"`, etc. Make sure `vertical` is available in this function — pass it as a parameter if it isn't already.

### 4. Fix source_category in `lib/dailyrag/pipeline/daily.ex`

Around line 204 in `enrich_segments`, change:

```elixir
"source_category" => "brand"
```

to:

```elixir
"source_category" => "ad-library"
```

### 5. Fix brand_source_detail in `lib/dailyrag/pipeline/daily.ex`

Around line 209 in `enrich_segments`, the brand source detail only stores the brand name. Change it to include the Meta Library ID:

```elixir
"brand_source_detail" => "#{brand.brand_name} / Lib ID #{segment["source_ad_id"]}"
```

### 6. Fix decay last_seen date in `lib/dailyrag/pipeline/daily.ex`

Around line 268 in `maybe_mark_inactive`, `last_seen` is set to today's date. It should be yesterday's date — the ad was last seen active yesterday, today is when we detected it's gone.

Change to:

```elixir
yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()
```

Use `yesterday` as the value written to the `last_seen` column (column M) in the Sheets update.

### 7. Fix or remove --recover flag

The `--recover` flag in `lib/mix/tasks/dailyrag.ex` is parsed and passed to `Daily.run/1`, but `run/1` never reads it. `Checkpoint.load/0` is never called. The flag does nothing.

**Pick the simpler option for now:** Remove the `--recover` option from the mix task's OptionParser, remove any reference to `opts.recover` in `Daily.run/1`, and delete the `Checkpoint` module if nothing else uses it. Add a code comment: `# TODO: implement --recover with checkpoint logic`. We will implement it properly later.

---

## PHASE 1 VERIFICATION

After making all 7 fixes:

1. Run `mix compile --warnings-as-errors` — must compile clean with zero warnings.
2. Run `mix test` — fix any test failures caused by the changes (especially schema tests that assert on column counts or field values that changed).
3. Run `mix dailyrag --dry-run --verbose` — confirm the pipeline boots and completes without crashes. No writes to Google Sheets in dry-run mode.
4. Post to `#rag-builder`: "Phase 1 fixes complete — 7/7 items done. Dry-run passed. Ready for single-brand live test."

---

## PHASE 2 — Fix these after Phase 1 is verified and a successful live run on one brand.

### 8. Segment type enum — update Claude prompt to use structural segments

In `lib/dailyrag/segmenter.ex` around lines 59-63, the Claude prompt uses creative angle categories ("Problem-Solution", "Social Proof/UGC", "Before/After Transformation"). Update the prompt to use the structural segment taxonomy instead: `hook`, `body`, `CTA`, `offer`, `social_proof`, `education`, `b_roll_direction`. Each ad should be broken into these structural parts, not classified by creative angle. Match the format used in the master Entries sheet (2,330 existing rows use this taxonomy).

### 9. Guard dry-run from Sheets tab creation

In `lib/dailyrag/pipeline/daily.ex` around line 15, `TabInit.ensure_tabs!` runs even in dry-run mode. Wrap it:

```elixir
unless opts.dry_run, do: TabInit.ensure_tabs!(sheet_id)
```

### 10. Fix --brand flag to only scrape the specified brand

In `lib/dailyrag/pipeline/daily.ex` around line 92, `--brand` only filters segmentation, not scraping. When `--brand` is set, filter `active_brands` to only the specified brand before passing to `scrape_all_brands`. A single-brand run should only scrape that one brand.

### 11. Add inter-brand delay to prevent bot detection

In `lib/dailyrag/pipeline/daily.ex` around line 94, the `Enum.reduce` loop over brands has no pause between scrapes. Add `Process.sleep(delay_ms)` between each brand scrape. Default to 3000ms. Make it configurable via a `SCRAPE_DELAY_MS` environment variable:

```elixir
delay = System.get_env("SCRAPE_DELAY_MS", "3000") |> String.to_integer()
Process.sleep(delay)
```

### 12. Add retry-with-backoff to Python scraper

In `priv/scraper/scrape_ads.py` around lines 125-153, the scraper tries StealthyFetcher then DynamicFetcher with no retry loop. Wrap the full sequence (StealthyFetcher → DynamicFetcher) in a retry loop: 2 attempts with exponential backoff (5 seconds on first retry, 15 seconds on second). Log each retry attempt.

---

## PHASE 2 VERIFICATION

1. Run `mix compile --warnings-as-errors` and `mix test`.
2. Run `mix dailyrag --brand "Ghost" --verbose` — confirm only Ghost is scraped, segments match the structural taxonomy, and the Sheets row has correct schema.
3. Post to `#rag-builder`: "Phase 2 fixes complete — 5/5 items done. Single-brand live test passed on Ghost."

---

## PHASE 3 — Fix before Sunday (when the weekly discovery run fires).

### 13. Fix discovery pipeline crash

Two problems in the discovery flow:

**Problem A:** In `lib/dailyrag/scraper.ex` lines 32-41, `run_python/2` has no case clause matching `{:ok, %{"html" => ...}}`. When discovery mode returns raw HTML, this crashes with `CaseClauseError`. Add a catch-all clause:

```elixir
{:ok, other} -> {:ok, other}
```

**Problem B:** No logic exists to parse the raw HTML into brand data. The discovery flow needs to either:
- (Preferred) Update `priv/scraper/scrape_ads.py` discovery mode to parse Meta Ad Library search results in Python and return a JSON list of brand maps: `[{"brand_name": "...", "meta_library_url": "...", "estimated_ad_count": N}, ...]`
- Or add a Claude call in Elixir to parse the HTML into the same structure.

Choose whichever approach you can implement more reliably. The output must be a list of brand maps that can be appended to the `Discovery_Queue` tab.

### 14. Fix Discovery_Queue schema

In `lib/dailyrag/sheets/schema.ex` lines 37-46, update the Discovery_Queue headers and schema to match this exact column order:

`brand_name | vertical | meta_library_url | keyword_source | estimated_ad_count | date_found | status`

Remove `page_id`. Add `estimated_ad_count` (integer). Rename `discovered_date` to `date_found`.

---

## PHASE 3 VERIFICATION

1. Run `mix dailyrag --discover --dry-run --verbose` — confirm discovery runs without crashing and logs the brands it would have found.
2. Post to `#rag-builder`: "Phase 3 fixes complete — discovery pipeline functional. Ready for Sunday run."

---

## PHASE 4 — Cleanup. Do these when Phases 1-3 are done and the pipeline has run successfully for at least 2 days.

### 15. Fix segmenter test
`test/dailyrag/segmenter_test.exs` mocks an HTTP client the segmenter doesn't use. Rewrite to mock `System.cmd` by making the command runner injectable (configurable module attribute or wrapper function).

### 16. Fix schema test assertions
`test/dailyrag/sheets/schema_test.exs` — line 9 expects 4 discovery_keywords headers (there are 3), line 11 expects 8 daily_report headers (there are 16), line 49 references `parsed.page_id` which doesn't exist. Update all assertions to match current schema.

### 17. Stop overwriting Sheets headers every run
`lib/dailyrag/sheets/tab_init.ex:18` — move the `update_range` call inside the `unless tab in existing_tabs` block so headers are only written when a tab is newly created.

### 18. Delete dead Goth GenServer
`lib/goth.ex` is never started or used. `Client` handles its own token refresh. Delete the file.

### 19. Fix rotation fragility
`lib/dailyrag/rotation.ex:46` — rotation stores an integer index into the brand list. If brands are added or reordered, the index points to the wrong brand. Change to store brand names instead of index position. On each run, pick the next 3 brand names that haven't been segmented in the current cycle.

### 20. Update Slack summary format
`lib/dailyrag/slack.ex:13-36` — update to match the format in the PDR: add line separators (`━━━━━━`), include "Brands with zero new ads" list, include "Brands with zero active ads (⚠️ possible scrape issue)" warning line.

### 21. Add notes column to Brand_Config
The Brand_Config schema has 6 columns but the PDR defines 7 (including optional `notes`). Add `notes` as the 7th column header.

---

## FULL ROLLOUT SEQUENCE (after all Phase 1 fixes pass)

Execute these steps in order. Do not skip any step.

| Step | Command | Pass Criteria |
|------|---------|---------------|
| 1 | `mix dailyrag --dry-run --verbose` | Completes without error. No Sheets writes. Logs show all 18 brands scraped. |
| 2 | `mix dailyrag --brand "Ghost" --verbose` | Ghost scraped and segmented. Check Sheets: Entry# is `SD-XXXX`, Source Category is `ad-library`, Confidence calculated from start_date. |
| 3 | `mix dailyrag --verbose` | Full run: 18 brands scraped, 3 segmented on rotation. Daily_Report row appended. `#rag-builder` notification posted. Completes within 60 minutes. |
| 4 | Verify Sheets output | All 6 tabs exist. Column order matches PDR. Confidence values are correct. Decay `last_seen` dates are correct. |
| 5 | Enable OpenClaw cron — daily at 6 AM MT | Pipeline runs unattended. |
| 6 | Next morning: check `#rag-builder` and Daily_Report | Notification posted by 7:30 AM MT. Report row has correct counts. |

Do not enable the OpenClaw cron until steps 1-4 pass cleanly.
