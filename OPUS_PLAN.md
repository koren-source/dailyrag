# OPUS_PLAN.md — Cutbox Daily RAG Enrichment Pipeline

> Implementation plan for Codex 5.4. Every module, function signature, data structure,
> and API call is specified. Build in the exact order given in Section 13.

---

## 1. Project Structure

```
dailyrag/
├── mix.exs                          # Dependencies and project config
├── .formatter.exs                   # Elixir formatter config
├── .gitignore                       # Ignore data/, .env, _build, deps
├── .env.example                     # Required environment variables
├── config/
│   ├── config.exs                   # Compile-time config (mostly empty)
│   └── runtime.exs                  # Runtime config — reads env vars
├── lib/
│   ├── dailyrag.ex                  # Top-level module, version constant
│   ├── dailyrag/
│   │   ├── application.ex           # OTP Application — starts Goth supervisor
│   │   ├── sheets/
│   │   │   ├── client.ex            # Raw Google Sheets API via Req
│   │   │   ├── tab_init.ex          # First-run tab creation + seeding
│   │   │   └── schema.ex            # Column mappings and row builders
│   │   ├── scraper.ex               # Python sidecar caller (System.cmd)
│   │   ├── segmenter.ex             # Claude Sonnet 4.6 API caller
│   │   ├── dedup.ex                 # Dedup index read/write/check
│   │   ├── decay.ex                 # Decay cache + confidence logic
│   │   ├── checkpoint.ex            # Checkpoint + recovery + failed writes
│   │   ├── slack.ex                 # Slack message posting via Req
│   │   ├── pipeline/
│   │   │   ├── daily.ex             # Daily pipeline orchestrator
│   │   │   └── discovery.ex         # Weekly discovery orchestrator
│   │   └── util.ex                  # Atomic file writes, date helpers
│   └── mix/
│       └── tasks/
│           └── dailyrag.ex          # `mix dailyrag` CLI entry point
├── priv/
│   └── scraper/
│       ├── scrape_ads.py            # Meta Ad Library scraper (Scrapling)
│       ├── scrape_discovery.py      # Discovery keyword search scraper
│       └── requirements.txt         # Python dependencies
├── data/                            # Created at runtime, gitignored
│   ├── dedup_index.json
│   ├── decay_cache.json
│   ├── checkpoint.json
│   └── failed_writes.json
└── test/
    ├── test_helper.exs
    └── dailyrag/
        ├── dedup_test.exs
        ├── decay_test.exs
        ├── checkpoint_test.exs
        ├── sheets/
        │   └── schema_test.exs
        └── segmenter_test.exs
```

---

## 2. mix.exs — Exact Dependencies

```elixir
defp deps do
  [
    {:req, "~> 0.5"},          # HTTP client for Sheets API, Slack API, Claude API
    {:jason, "~> 1.4"},        # JSON encoding/decoding everywhere
    {:goth, "~> 1.4"},         # Google OAuth2 token refresh (supports user tokens)
  ]
end

def application do
  [
    extra_applications: [:logger],
    mod: {DailyRag.Application, []}
  ]
end
```

**Why we skip `google_api_sheets`:** It hard-depends on `tesla` + `poison` (legacy JSON lib).
The Sheets REST API is 5 endpoints — cleaner to call them directly with Req.

**Why no `tesla`, `hackney`, `finch`:** Req bundles Finch internally. No separate HTTP adapter needed.

---

## 3. Module-by-Module Spec

### 3.1 `DailyRag` (`lib/dailyrag.ex`)

```elixir
defmodule DailyRag do
  @version "0.1.0"
  def version, do: @version
end
```

Nothing else. Just the namespace root.

### 3.2 `DailyRag.Application` (`lib/dailyrag/application.ex`)

```elixir
defmodule DailyRag.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Goth,
       name: DailyRag.Goth,
       source:
         {:refresh_token,
          %{
            "client_id" => Application.fetch_env!(:dailyrag, :google_client_id),
            "client_secret" => Application.fetch_env!(:dailyrag, :google_client_secret),
            "refresh_token" => Application.fetch_env!(:dailyrag, :google_refresh_token)
          }}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DailyRag.Supervisor)
  end
end
```

**Gotcha:** Goth must be started before any Sheets calls. The supervision tree ensures this.

### 3.3 `DailyRag.Sheets.Client` (`lib/dailyrag/sheets/client.ex`)

Public API:

```elixir
defmodule DailyRag.Sheets.Client do
  @base "https://sheets.googleapis.com/v4/spreadsheets"

  # List all tab names in the spreadsheet
  @spec list_tabs(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_tabs(sheet_id)

  # Read all rows from a tab. Returns list of lists (rows).
  # range example: "Brand_Config!A:F"
  @spec read_range(String.t(), String.t()) :: {:ok, [[String.t()]]} | {:error, term()}
  def read_range(sheet_id, range)

  # Append rows to a tab. rows = [[col1, col2, ...], ...]
  @spec append_rows(String.t(), String.t(), [[String.t()]]) :: :ok | {:error, term()}
  def append_rows(sheet_id, range, rows)

  # Update a single cell or small range. values = [["new_val"]]
  @spec update_range(String.t(), String.t(), [[String.t()]]) :: :ok | {:error, term()}
  def update_range(sheet_id, range, values)

  # Batch update multiple ranges at once.
  # updates = [%{range: "Tab!I5", values: [["curated"]]}, ...]
  @spec batch_update(String.t(), [map()]) :: :ok | {:error, term()}
  def batch_update(sheet_id, updates)

  # Create a new tab (sheet) in the spreadsheet
  @spec create_tab(String.t(), String.t()) :: :ok | {:error, term()}
  def create_tab(sheet_id, title)
end
```

**Implementation notes:**
- Every function calls `get_token/0` which does `Goth.fetch(DailyRag.Goth)` and extracts the access token string.
- Every function wraps the HTTP call in `with_retry/1` (3 attempts, exponential backoff: 1s, 2s, 4s).
- All requests use `Req.get!/post!/put!` with `headers: [{"authorization", "Bearer #{token}"}]`.
- On 429 or 5xx, retry. On 4xx (except 429), return `{:error, response}` immediately.
- `read_range/2` returns `{:ok, []}` if the range is empty (no data), not an error.

**`with_retry/1` helper (private):**

```elixir
defp with_retry(fun, attempts \\ 3, delay \\ 1000)
defp with_retry(_fun, 0, _delay), do: {:error, :max_retries}
defp with_retry(fun, attempts, delay) do
  case fun.() do
    {:ok, _} = ok -> ok
    :ok -> :ok
    {:error, %Req.Response{status: status}} when status in [429, 500, 502, 503] ->
      Process.sleep(delay)
      with_retry(fun, attempts - 1, delay * 2)
    {:error, _} = err -> err
  end
end
```

### 3.4 `DailyRag.Sheets.TabInit` (`lib/dailyrag/sheets/tab_init.ex`)

```elixir
defmodule DailyRag.Sheets.TabInit do
  # Ensures all required tabs exist. Creates missing ones with headers.
  # Call this at the start of every pipeline run.
  @spec ensure_tabs!(String.t()) :: :ok
  def ensure_tabs!(sheet_id)

  # Seeds Brand_Config with initial data if the tab is empty (header only).
  @spec seed_brand_config!(String.t()) :: :ok
  def seed_brand_config!(sheet_id)

  # Seeds Discovery_Keywords with initial data if empty.
  @spec seed_discovery_keywords!(String.t()) :: :ok
  def seed_discovery_keywords!(sheet_id)
end
```

**Implementation notes:**
- `ensure_tabs!/1` calls `Client.list_tabs/1`, diffs against required tab names, creates missing ones via `Client.create_tab/2`, then appends header rows.
- Required tabs: `Brand_Config`, `Discovery_Keywords`, `Discovery_Queue`, `Supplements_Daily`, `HomeServices_Daily`, `Daily_Report`
- After creating each tab, immediately append the header row for that tab.
- `seed_brand_config!/1` checks if `Brand_Config` has > 1 row (more than just header). If not, appends the initial brand rows from `brand_seed_data/0`.
- Idempotent: safe to call multiple times.

### 3.5 `DailyRag.Sheets.Schema` (`lib/dailyrag/sheets/schema.ex`)

```elixir
defmodule DailyRag.Sheets.Schema do
  # Column headers for each tab
  @spec daily_headers() :: [String.t()]
  def daily_headers do
    ["Entry#", "Segment Type", "Vertical", "Format", "Principle", "Transcript",
     "Why It Works", "Source Category", "Confidence", "Brand/Source Detail",
     "Notes", "date_discovered", "last_seen", "status", "ad_id"]
  end

  @spec brand_config_headers() :: [String.t()]
  def brand_config_headers do
    ["brand_name", "vertical", "meta_library_url", "page_id", "status", "added_date"]
  end

  @spec discovery_keywords_headers() :: [String.t()]
  def discovery_keywords_headers do
    ["keyword", "vertical", "status", "last_searched"]
  end

  @spec discovery_queue_headers() :: [String.t()]
  def discovery_queue_headers do
    ["brand_name", "vertical", "meta_library_url", "page_id",
     "discovered_date", "keyword_source", "status"]
  end

  @spec daily_report_headers() :: [String.t()]
  def daily_report_headers do
    ["date", "brands_processed", "new_ads_found", "ads_decayed",
     "confidence_upgrades", "errors", "duration_seconds", "notes"]
  end

  # Build a daily tab row from a segment map + metadata
  @spec build_daily_row(map(), integer()) :: [String.t()]
  def build_daily_row(segment, entry_number)

  # Parse a Brand_Config row (list of strings) into a map
  @spec parse_brand_config_row([String.t()]) :: map()
  def parse_brand_config_row(row)

  # Determine target tab name from vertical string
  @spec tab_for_vertical(String.t()) :: String.t()
  def tab_for_vertical("supplements"), do: "Supplements_Daily"
  def tab_for_vertical("home_services"), do: "HomeServices_Daily"
end
```

**Implementation notes:**
- `build_daily_row/2` takes a map like `%{segment_type: "...", principle: "...", ...}` and returns a 15-element list matching columns A–O.
- `parse_brand_config_row/1` takes `["AG1", "supplements", "https://...", "12345", "active", "2026-03-12"]` and returns `%{brand_name: "AG1", vertical: "supplements", ...}`.
- Column positions are hardcoded (A=0, B=1, ..., O=14). No dynamic lookup.

### 3.6 `DailyRag.Scraper` (`lib/dailyrag/scraper.ex`)

```elixir
defmodule DailyRag.Scraper do
  @script_path Path.join(:code.priv_dir(:dailyrag), "scraper/scrape_ads.py")
  @discovery_script_path Path.join(:code.priv_dir(:dailyrag), "scraper/scrape_discovery.py")

  # Scrape ads from a Meta Ad Library URL.
  # Returns list of ad maps or {:error, reason}.
  @spec scrape_ads(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def scrape_ads(url)

  # Scrape discovery results for a keyword search.
  @spec scrape_discovery(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def scrape_discovery(keyword)
end
```

**Implementation notes:**
- Uses `System.cmd("python3", [@script_path, url], stderr_to_stdout: true)`.
- On exit code 0: `Jason.decode!(output)` → expect a list of maps.
- On exit code non-0: try `Jason.decode(output)` for `%{"error" => msg}`, else `{:error, output}`.
- Timeout: Set `timeout: 120_000` (2 minutes per brand). Meta pages are slow.
- **Gotcha:** `@script_path` uses compile-time `priv_dir`. This works in releases but during dev, ensure `priv/scraper/` exists.
- Actually, use a function instead of module attribute for `priv_dir` since it's not available at compile time in all contexts:

```elixir
defp script_path, do: Path.join(:code.priv_dir(:dailyrag), "scraper/scrape_ads.py")
```

### 3.7 `DailyRag.Segmenter` (`lib/dailyrag/segmenter.ex`)

```elixir
defmodule DailyRag.Segmenter do
  @api_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-6"

  # Segment a batch of ads for one brand.
  # Returns a flat list of segment maps.
  @spec segment_ads(String.t(), String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def segment_ads(brand_name, vertical, ads)
end
```

**Implementation notes:**
- Batches up to 10 ads per API call. If a brand has 25 ads, makes 3 calls (10, 10, 5).
- Each call sends the ads as a single user message, expects a JSON array response.
- On API error (429, 5xx), retry 2x with 2s/4s backoff. On persistent failure, return `{:error, reason}`.
- Parse response: extract `content[0].text`, `Jason.decode!/1` it, validate it's a list.
- Each segment map in the response must have keys: `segment_type`, `principle`, `transcript`, `why_it_works`, `format`.
- If a key is missing, fill with `"unknown"`.
- See Section 6 for exact request body and prompts.

### 3.8 `DailyRag.Dedup` (`lib/dailyrag/dedup.ex`)

```elixir
defmodule DailyRag.Dedup do
  @path "data/dedup_index.json"

  # Load the dedup index from disk. Returns empty map if file missing.
  @spec load() :: map()
  def load()

  # Check if an ad_id is already known.
  @spec known?(map(), String.t()) :: boolean()
  def known?(index, ad_id)

  # Add new ad_ids to the index. brand + date.
  @spec add(map(), String.t(), [String.t()]) :: map()
  def add(index, brand_name, ad_ids)

  # Persist the index to disk (atomic write).
  @spec save!(map()) :: :ok
  def save!(index)

  # Filter a list of ads, returning only those NOT in the index.
  @spec filter_new(map(), [map()]) :: [map()]
  def filter_new(index, ads)
end
```

**Data structure — see Section 7.**

### 3.9 `DailyRag.Decay` (`lib/dailyrag/decay.ex`)

```elixir
defmodule DailyRag.Decay do
  @path "data/decay_cache.json"

  # Load the decay cache from disk.
  @spec load() :: map()
  def load()

  # Compare today's ad_ids against yesterday's for a brand.
  # Returns {disappeared_ids, new_ids}.
  @spec diff(map(), String.t(), [String.t()]) :: {[String.t()], [String.t()]}
  def diff(cache, brand_name, todays_ad_ids)

  # Update the cache with today's ad_ids for a brand.
  @spec update(map(), String.t(), [String.t()]) :: map()
  def update(cache, brand_name, todays_ad_ids)

  # Persist to disk (atomic write).
  @spec save!(map()) :: :ok
  def save!(cache)

  # DOM canary check: brand had >5 ads yesterday, 0 today.
  @spec canary_warning?(map(), String.t(), [String.t()]) :: boolean()
  def canary_warning?(cache, brand_name, todays_ad_ids)

  # Compute confidence upgrades for active rows.
  # Takes a list of row maps (with date_discovered and current confidence).
  # Returns list of {row_index, new_confidence} for rows that need upgrading.
  @spec confidence_upgrades([map()], Date.t()) :: [{integer(), String.t()}]
  def confidence_upgrades(rows, today)
end
```

**Confidence rules:**
- `"emerging"` → `"curated"` when `today - date_discovered >= 14 days`
- `"curated"` → `"verified"` when `today - date_discovered >= 30 days`
- `"verified"` stays `"verified"` (never downgrades)
- Default for new rows: `"emerging"`

### 3.10 `DailyRag.Checkpoint` (`lib/dailyrag/checkpoint.ex`)

```elixir
defmodule DailyRag.Checkpoint do
  @cp_path "data/checkpoint.json"
  @fw_path "data/failed_writes.json"

  # Save a checkpoint after each brand completes.
  @spec save!(map()) :: :ok
  def save!(state)

  # Load checkpoint for recovery. Returns nil if no checkpoint.
  @spec load() :: map() | nil
  def load()

  # Clear the checkpoint file (called on successful completion).
  @spec clear!() :: :ok
  def clear!()

  # Record a failed Sheets write for later retry.
  @spec record_failed_write!(map()) :: :ok
  def record_failed_write!(write_info)

  # Load any pending failed writes.
  @spec pending_writes() :: [map()]
  def pending_writes()

  # Clear all pending writes (called after successful retry).
  @spec clear_pending_writes!() :: :ok
  def clear_pending_writes!()
end
```

### 3.11 `DailyRag.Slack` (`lib/dailyrag/slack.ex`)

```elixir
defmodule DailyRag.Slack do
  @api_url "https://slack.com/api/chat.postMessage"

  # Post a text message to the configured Slack channel.
  @spec post(String.t()) :: :ok | {:error, term()}
  def post(text)

  # Post with blocks (for richer formatting).
  @spec post_blocks(String.t(), [map()]) :: :ok | {:error, term()}
  def post_blocks(text, blocks)

  # Build a daily summary message from pipeline stats.
  @spec daily_summary(map()) :: String.t()
  def daily_summary(stats)

  # Build a discovery summary message.
  @spec discovery_summary(map()) :: String.t()
  def discovery_summary(stats)

  # Build a canary warning message.
  @spec canary_warning(String.t(), integer()) :: String.t()
  def canary_warning(brand_name, yesterday_count)
end
```

**Implementation notes:**
- POST with `Req.post!(@api_url, json: %{channel: channel, text: text}, headers: [{"authorization", "Bearer #{token}"}])`.
- `daily_summary/1` takes `%{brands_processed: 18, new_ads: 47, decayed: 12, upgrades: 5, warnings: [...], duration_s: 263}` and formats a readable message.

### 3.12 `DailyRag.Pipeline.Daily` (`lib/dailyrag/pipeline/daily.ex`)

```elixir
defmodule DailyRag.Pipeline.Daily do
  # Run the full daily pipeline.
  # opts: %{dry_run: bool, brand: nil | String.t(), recover: bool, verbose: bool}
  @spec run(map()) :: :ok | {:error, term()}
  def run(opts)
end
```

**Orchestration sequence:**
```
1. ensure_data_dir!()
2. Sheets.TabInit.ensure_tabs!(sheet_id)
3. Retry any pending failed writes from last run
4. If --recover, load checkpoint → skip to brand at saved index
5. Read Brand_Config → filter to active brands
6. If --brand, filter to just that brand
7. Load dedup index + decay cache
8. For each brand (sequential):
   a. Log: "Processing #{brand.name}..."
   b. Scraper.scrape_ads(brand.meta_library_url)
      - On error: log warning, record in stats, CONTINUE to next brand
   c. Dedup.filter_new(index, ads) → new_ads
   d. If new_ads not empty:
      - Segmenter.segment_ads(brand.name, brand.vertical, new_ads)
      - On error: log, skip segmentation, still record raw ads
   e. Decay.diff(cache, brand.name, all_ad_ids_today)
      - If canary_warning?: post to Slack immediately
      - disappeared_ids → mark as inactive in Sheet (update status col)
   f. Build daily rows from segments
   g. If NOT dry_run:
      - Append rows to correct daily tab
      - Update dedup index + decay cache
   h. Save checkpoint
   i. Log: "Done with #{brand.name}: #{length(new_ads)} new ads"
9. Confidence upgrades: read ALL active rows, compute upgrades, batch_update
10. Build Daily_Report row, append to Daily_Report tab
11. Post daily summary to Slack
12. Clear checkpoint
13. Save final dedup index + decay cache
```

**dry_run behavior:** Logs everything, prints rows that WOULD be written, skips Sheets writes and Slack posts.

**verbose behavior:** Logs each ad being processed, full Claude prompt/response, Sheets API calls.

### 3.13 `DailyRag.Pipeline.Discovery` (`lib/dailyrag/pipeline/discovery.ex`)

```elixir
defmodule DailyRag.Pipeline.Discovery do
  # Run the weekly discovery pipeline.
  @spec run(map()) :: :ok | {:error, term()}
  def run(opts)
end
```

**Orchestration sequence:**
```
1. Sheets.TabInit.ensure_tabs!(sheet_id)
2. Read Discovery_Keywords → filter to active keywords
3. Read Brand_Config → get existing brand names (for diffing)
4. Read Discovery_Queue → get already-queued brands
5. For each keyword:
   a. Scraper.scrape_discovery(keyword)
   b. Filter out brands already in Brand_Config or Discovery_Queue
   c. Collect new brands
6. If new brands found:
   - Append to Discovery_Queue with status="pending"
7. Check Discovery_Queue for status="approved" brands
   - For each approved: copy to Brand_Config with status="active"
   - Update Discovery_Queue status to "promoted"
8. Post discovery summary to Slack
```

### 3.14 `DailyRag.Util` (`lib/dailyrag/util.ex`)

```elixir
defmodule DailyRag.Util do
  # Atomic write: write to .tmp file, then rename.
  @spec atomic_write!(String.t(), String.t()) :: :ok
  def atomic_write!(path, content)

  # Ensure data directory exists.
  @spec ensure_data_dir!() :: :ok
  def ensure_data_dir!()

  # Today's date as ISO string.
  @spec today() :: String.t()
  def today()

  # Parse ISO date string to Date.
  @spec parse_date(String.t()) :: Date.t()
  def parse_date(date_string)
end
```

### 3.15 `Mix.Tasks.Dailyrag` (`lib/mix/tasks/dailyrag.ex`)

```elixir
defmodule Mix.Tasks.Dailyrag do
  use Mix.Task

  @shortdoc "Run the DailyRag enrichment pipeline"

  @switches [
    dry_run: :boolean,
    brand: :string,
    recover: :boolean,
    discover: :boolean,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    Mix.Task.run("app.start")    # Starts OTP app (Goth, etc.)

    opts_map = %{
      dry_run: Keyword.get(opts, :dry_run, false),
      brand: Keyword.get(opts, :brand),
      recover: Keyword.get(opts, :recover, false),
      discover: Keyword.get(opts, :discover, false),
      verbose: Keyword.get(opts, :verbose, false)
    }

    if opts_map.discover do
      DailyRag.Pipeline.Discovery.run(opts_map)
    else
      DailyRag.Pipeline.Daily.run(opts_map)
    end
  end
end
```

---

## 4. Google Sheets Integration Plan

### Credential Type: OAuth2 User Token (NOT service account)

The file at `~/.openclaw/workspace/credentials/google-token.json` contains:
- `token` — short-lived access token (will be expired)
- `refresh_token` — long-lived, used by Goth to get fresh access tokens
- `client_id` / `client_secret` — OAuth2 client credentials
- Scopes include `spreadsheets` and `drive` — both needed

**Goth Configuration:**

```elixir
# In Application.start/2:
{Goth,
 name: DailyRag.Goth,
 source: {:refresh_token, %{
   "client_id" => Application.fetch_env!(:dailyrag, :google_client_id),
   "client_secret" => Application.fetch_env!(:dailyrag, :google_client_secret),
   "refresh_token" => Application.fetch_env!(:dailyrag, :google_refresh_token)
 }}}
```

Goth handles token refresh automatically. Call `Goth.fetch(DailyRag.Goth)` to get a valid `%Goth.Token{token: "ya29..."}`.

### API Call Patterns

**Base URL:** `https://sheets.googleapis.com/v4/spreadsheets`

**Auth header on every request:**
```elixir
{:ok, %{token: access_token}} = Goth.fetch(DailyRag.Goth)
headers = [{"authorization", "Bearer #{access_token}"}]
```

#### List tabs (check which exist):
```
GET /v4/spreadsheets/{sheet_id}?fields=sheets.properties.title
```
```elixir
Req.get!("#{@base}/#{sheet_id}", headers: headers, params: [fields: "sheets.properties.title"])
```
Response: `%{"sheets" => [%{"properties" => %{"title" => "Sheet1"}}, ...]}`

#### Create a tab:
```
POST /v4/spreadsheets/{sheet_id}:batchUpdate
```
```elixir
Req.post!("#{@base}/#{sheet_id}:batchUpdate",
  headers: headers,
  json: %{requests: [%{addSheet: %{properties: %{title: tab_name}}}]}
)
```

#### Read a range:
```
GET /v4/spreadsheets/{sheet_id}/values/{range}
```
```elixir
range = URI.encode("Brand_Config!A:F")
resp = Req.get!("#{@base}/#{sheet_id}/values/#{range}", headers: headers)
rows = resp.body["values"] || []  # Returns [] if empty
```

#### Append rows:
```
POST /v4/spreadsheets/{sheet_id}/values/{range}:append
  ?valueInputOption=RAW&insertDataOption=INSERT_ROWS
```
```elixir
range = URI.encode("Supplements_Daily!A:O")
Req.post!("#{@base}/#{sheet_id}/values/#{range}:append",
  headers: headers,
  params: [valueInputOption: "RAW", insertDataOption: "INSERT_ROWS"],
  json: %{values: rows}
)
```

#### Update specific cells:
```
PUT /v4/spreadsheets/{sheet_id}/values/{range}?valueInputOption=RAW
```
```elixir
# Update a single cell (e.g., confidence in column I, row 5):
range = URI.encode("Supplements_Daily!I5")
Req.put!("#{@base}/#{sheet_id}/values/#{range}",
  headers: headers,
  params: [valueInputOption: "RAW"],
  json: %{values: [["curated"]]}
)
```

#### Batch update multiple cells:
```
POST /v4/spreadsheets/{sheet_id}/values:batchUpdate
```
```elixir
Req.post!("#{@base}/#{sheet_id}/values:batchUpdate",
  headers: headers,
  json: %{
    valueInputOption: "RAW",
    data: [
      %{range: "Supplements_Daily!I5", values: [["curated"]]},
      %{range: "Supplements_Daily!N12", values: [["inactive"]]},
    ]
  }
)
```

Use batch update for:
- Decay: marking multiple ads as `inactive` in column N
- Confidence: upgrading multiple ads in column I
- Updating `last_seen` (column M) for still-active ads

---

## 5. Python Sidecar Implementation Plan

### `priv/scraper/requirements.txt`

```
scrapling[stealth]
```

This installs Scrapling + Camoufox (stealth Firefox) + Playwright. After `pip install`, run `scrapling install` to download browser binaries.

### `priv/scraper/scrape_ads.py` — Complete Pseudocode

```python
#!/usr/bin/env python3
"""
Meta Ad Library scraper.
Input: URL as argv[1]
Output (stdout): JSON array of ad objects
Error: {"error": "message"} + exit 1

Contract:
  Each ad object: {"ad_id": str, "copy": str, "start_date": str, "headline": str}
"""
import sys
import json
import time
import re

from scrapling.fetchers import StealthyFetcher


def scrape_ads(url: str) -> list[dict]:
    captured_responses: list[dict] = []

    def page_action(page):
        """Runs after initial page load with the live Playwright Page object."""
        # 1. Set up GraphQL response interception
        def on_response(response):
            try:
                if "graphql" in response.url or "api/graphql" in response.url:
                    body = response.json()
                    captured_responses.append(body)
            except Exception:
                pass

        page.on("response", on_response)

        # 2. Scroll down to trigger lazy-loading of additional ads.
        #    Meta Ad Library loads ~20 ads initially, more on scroll.
        for i in range(15):
            page.mouse.wheel(0, 2500)
            page.wait_for_timeout(1500 + (i * 200))  # Increasing delays look more human

        # 3. Small pause to catch trailing network responses
        page.wait_for_timeout(3000)

    # Fetch with stealth browser
    page = StealthyFetcher.fetch(
        url,
        headless=True,
        network_idle=True,
        page_action=page_action,
        timeout=90000,
    )

    # Parse GraphQL responses for ad data
    ads = extract_from_graphql(captured_responses)

    # Fallback: if GraphQL interception yielded nothing, parse DOM
    if not ads:
        ads = extract_from_dom(page)

    return ads


def extract_from_graphql(responses: list[dict]) -> list[dict]:
    """Recursively search GraphQL response JSON for ad data nodes."""
    raw_ads = []
    for resp in responses:
        raw_ads.extend(find_ad_nodes(resp))

    # Deduplicate by ad_archive_id within this scrape
    seen = set()
    ads = []
    for ad_node in raw_ads:
        ad_id = str(ad_node.get("ad_archive_id") or ad_node.get("adArchiveID") or "")
        if not ad_id or ad_id in seen:
            continue
        seen.add(ad_id)

        # Extract copy text — varies by GraphQL schema version
        copy = ""
        if "body" in ad_node and isinstance(ad_node["body"], dict):
            copy = ad_node["body"].get("text", "")
        elif "body" in ad_node and isinstance(ad_node["body"], str):
            copy = ad_node["body"]
        elif "snapshot" in ad_node:
            snap = ad_node["snapshot"]
            if isinstance(snap, dict):
                copy = snap.get("body", {}).get("text", "") if isinstance(snap.get("body"), dict) else snap.get("body", "")

        headline = ""
        if "title" in ad_node:
            headline = ad_node["title"] if isinstance(ad_node["title"], str) else ad_node["title"].get("text", "")

        start_date = ad_node.get("start_date") or ad_node.get("startDate") or ad_node.get("creation_time") or ""

        ads.append({
            "ad_id": ad_id,
            "copy": copy.strip(),
            "headline": headline.strip() if headline else "",
            "start_date": str(start_date),
        })
    return ads


def find_ad_nodes(data, depth=0) -> list[dict]:
    """Recursively find dicts that contain ad_archive_id or adArchiveID."""
    if depth > 15:
        return []
    results = []
    if isinstance(data, dict):
        if "ad_archive_id" in data or "adArchiveID" in data:
            results.append(data)
        for v in data.values():
            results.extend(find_ad_nodes(v, depth + 1))
    elif isinstance(data, list):
        for item in data:
            results.extend(find_ad_nodes(item, depth + 1))
    return results


def extract_from_dom(page) -> list[dict]:
    """
    Fallback DOM parsing. Facebook uses obfuscated classes, so we rely on:
    - Structural patterns (nested divs)
    - Text content matching ("Started running on...")
    - Links containing ad archive IDs
    """
    ads = []

    # Find all links containing ad archive IDs
    ad_links = page.css('a[href*="/ads/library/?id="]')
    seen_ids = set()

    for link in ad_links:
        href = link.attrib.get("href", "")
        # Extract ad_id from URL param
        match = re.search(r'[?&]id=(\d+)', href)
        if not match:
            continue
        ad_id = match.group(1)
        if ad_id in seen_ids:
            continue
        seen_ids.add(ad_id)

        # Walk up to the ad container (parent of parent pattern)
        # and extract text content
        container = link
        for _ in range(5):
            if container.parent:
                container = container.parent
            else:
                break

        text_content = container.text.strip() if hasattr(container, 'text') else ""

        # Try to extract start_date from text
        date_match = re.search(r'Started running on (.+?)(?:\n|$)', text_content)
        start_date = date_match.group(1).strip() if date_match else ""

        ads.append({
            "ad_id": ad_id,
            "copy": text_content[:2000],  # Cap length
            "headline": "",
            "start_date": start_date,
        })

    return ads


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: scrape_ads.py <url>"}))
        sys.exit(1)

    try:
        url = sys.argv[1]
        result = scrape_ads(url)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": f"{type(e).__name__}: {str(e)}"}))
        sys.exit(1)
```

### `priv/scraper/scrape_discovery.py` — Complete Pseudocode

```python
#!/usr/bin/env python3
"""
Meta Ad Library keyword search scraper.
Input: keyword as argv[1]
Output (stdout): JSON array of brand objects
  [{"brand_name": str, "page_id": str, "meta_library_url": str}, ...]
"""
import sys
import json
from scrapling.fetchers import StealthyFetcher
from urllib.parse import quote_plus

SEARCH_URL = "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q={keyword}"


def scrape_discovery(keyword: str) -> list[dict]:
    url = SEARCH_URL.format(keyword=quote_plus(keyword))
    captured = []

    def page_action(page):
        def on_response(response):
            try:
                if "graphql" in response.url:
                    captured.append(response.json())
            except:
                pass

        page.on("response", on_response)
        # Scroll to load more results
        for _ in range(8):
            page.mouse.wheel(0, 2000)
            page.wait_for_timeout(2000)

    page = StealthyFetcher.fetch(
        url,
        headless=True,
        network_idle=True,
        page_action=page_action,
        timeout=60000,
    )

    brands = extract_brands(captured)
    return brands


def extract_brands(responses):
    """Extract unique brand names + page IDs from GraphQL responses."""
    seen = set()
    brands = []
    for resp in responses:
        for node in find_page_nodes(resp):
            page_id = str(node.get("page_id") or node.get("pageID") or "")
            name = node.get("page_name") or node.get("pageName") or ""
            if not page_id or page_id in seen:
                continue
            seen.add(page_id)
            brands.append({
                "brand_name": name,
                "page_id": page_id,
                "meta_library_url": f"https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&view_all_page_id={page_id}",
            })
    return brands


def find_page_nodes(data, depth=0):
    if depth > 15:
        return []
    results = []
    if isinstance(data, dict):
        if "page_id" in data or "pageID" in data:
            results.append(data)
        for v in data.values():
            results.extend(find_page_nodes(v, depth + 1))
    elif isinstance(data, list):
        for item in data:
            results.extend(find_page_nodes(item, depth + 1))
    return results


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: scrape_discovery.py <keyword>"}))
        sys.exit(1)
    try:
        result = scrape_discovery(sys.argv[1])
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": f"{type(e).__name__}: {str(e)}"}))
        sys.exit(1)
```

### Elixir → Python Communication Pattern

In `DailyRag.Scraper`:

```elixir
def scrape_ads(url) do
  script = script_path()

  case System.cmd("python3", [script, url],
         stderr_to_stdout: true,
         env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
       ) do
    {output, 0} ->
      case Jason.decode(output) do
        {:ok, ads} when is_list(ads) -> {:ok, ads}
        {:ok, %{"error" => msg}} -> {:error, msg}
        {:error, _} -> {:error, "Invalid JSON from scraper: #{String.slice(output, 0..200)}"}
      end

    {output, _exit_code} ->
      case Jason.decode(output) do
        {:ok, %{"error" => msg}} -> {:error, msg}
        _ -> {:error, "Scraper crashed: #{String.slice(output, 0..200)}"}
      end
  end
end
```

---

## 6. Claude API Integration

### Request Structure

```elixir
def segment_ads(brand_name, vertical, ads) do
  # Batch into groups of 10
  ads
  |> Enum.chunk_every(10)
  |> Enum.flat_map(fn batch ->
    case call_claude(brand_name, vertical, batch) do
      {:ok, segments} -> segments
      {:error, reason} ->
        Logger.warning("Claude segmentation failed for #{brand_name}: #{inspect(reason)}")
        []
    end
  end)
end

defp call_claude(brand_name, vertical, ads_batch) do
  api_key = Application.fetch_env!(:dailyrag, :anthropic_api_key)

  user_content = build_user_prompt(brand_name, vertical, ads_batch)

  body = %{
    model: "claude-sonnet-4-6",
    max_tokens: 4096,
    system: system_prompt(),
    messages: [
      %{role: "user", content: user_content}
    ]
  }

  resp = Req.post!("https://api.anthropic.com/v1/messages",
    headers: [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ],
    json: body
  )

  case resp.status do
    200 ->
      text = get_in(resp.body, ["content", Access.at(0), "text"])
      parse_segments(text)
    status when status in [429, 500, 502, 503, 529] ->
      {:error, {:retryable, status}}
    status ->
      {:error, {:api_error, status, resp.body}}
  end
end
```

### System Prompt

```
You are an expert performance marketing analyst specializing in Meta ads
across supplements, home services, and DTC verticals. You analyze ad
creative (copy and structure) to extract actionable intelligence for
creative strategists.

For each ad, produce a JSON object with these exact keys:
- "segment_type": The creative angle category. Use one of: "Problem-Solution",
  "Social Proof/UGC", "Before/After Transformation", "Authority/Expert",
  "Urgency/Scarcity", "Educational/How-To", "Listicle/Reasons Why",
  "Emotional Story", "Comparison/Alternative", "Offer/Discount Lead",
  "Fear/Risk Awareness", "Curiosity Gap"
- "principle": The core psychological or marketing principle at work (1-2 sentences).
- "transcript": The full ad copy, cleaned (no emoji spam, fix formatting,
  preserve the actual words).
- "why_it_works": Sharp, specific analysis of WHY this ad is effective. Not
  generic platitudes. Reference specific lines or techniques in the ad.
  A creative strategist should be able to read this and immediately know what
  to replicate. 2-4 sentences.
- "format": Best guess at ad format: "video", "static_image", "carousel",
  "collection", "stories", "reel"

Return ONLY a valid JSON array. No markdown, no code fences, no explanation
outside the JSON. If an ad contains multiple distinct hooks or angles, create
one segment per angle. Most ads produce 1-2 segments.
```

### User Prompt Template

```
Analyze the following #{length(ads_batch)} Meta ad(s) from brand "#{brand_name}"
in the #{vertical} vertical.

#{for {ad, i} <- Enum.with_index(ads_batch, 1) do}
--- Ad #{i} (ID: #{ad["ad_id"]}) ---
#{ad["copy"]}
#{if ad["headline"] != "", do: "\nHeadline: #{ad["headline"]}", else: ""}
#{end}

Return a JSON array of segment objects. Include the ad_id in each segment
object as "source_ad_id" so I can trace which ad produced which segment.
```

### Response Parsing

```elixir
defp parse_segments(text) do
  # Claude sometimes wraps JSON in ```json ... ``` — strip that
  cleaned =
    text
    |> String.replace(~r/^```json\s*/m, "")
    |> String.replace(~r/\s*```$/m, "")
    |> String.trim()

  case Jason.decode(cleaned) do
    {:ok, segments} when is_list(segments) ->
      validated = Enum.map(segments, &validate_segment/1)
      {:ok, validated}
    {:ok, _} ->
      {:error, :not_a_list}
    {:error, reason} ->
      {:error, {:json_parse, reason}}
  end
end

defp validate_segment(seg) when is_map(seg) do
  %{
    "segment_type" => seg["segment_type"] || "unknown",
    "principle" => seg["principle"] || "",
    "transcript" => seg["transcript"] || "",
    "why_it_works" => seg["why_it_works"] || "",
    "format" => seg["format"] || "unknown",
    "source_ad_id" => seg["source_ad_id"] || ""
  }
end
```

---

## 7. Dedup + Decay Data Structures

### `data/dedup_index.json`

```json
{
  "version": 1,
  "ads": {
    "12345678": {
      "brand": "AG1",
      "first_seen": "2026-03-12"
    },
    "87654321": {
      "brand": "Onnit",
      "first_seen": "2026-03-10"
    }
  }
}
```

- Keyed by `ad_id` (string).
- `brand`: which brand this ad belongs to.
- `first_seen`: ISO date string when we first encountered it.
- On `Dedup.known?/2`: check `Map.has_key?(index["ads"], ad_id)`.
- On `Dedup.add/3`: merge new entries into `index["ads"]`.

### `data/decay_cache.json`

```json
{
  "version": 1,
  "date": "2026-03-12",
  "brands": {
    "AG1": ["12345678", "12345679", "12345680"],
    "Onnit": ["87654321", "87654322"]
  }
}
```

- `date`: the date these ad_ids were observed.
- `brands`: map of brand_name → list of ad_ids seen on that date.
- On `Decay.diff/3`: compare `cache["brands"][brand]` (yesterday) against `todays_ad_ids`.
  - Disappeared = yesterday_set -- today_set
  - New = today_set -- yesterday_set
- On `Decay.update/3`: replace the brand's ad_id list with today's list. Update `date` to today.
- `canary_warning?/3`: `length(yesterday_ids) > 5 and length(todays_ad_ids) == 0`

### `data/checkpoint.json`

```json
{
  "version": 1,
  "started_at": "2026-03-12T06:00:15Z",
  "completed_brands": ["AG1", "Onnit"],
  "current_brand_index": 2,
  "stats": {
    "new_ads": 15,
    "decayed": 3,
    "errors": 0
  }
}
```

- `current_brand_index`: index into the brands list. On recovery, skip to this index.
- `completed_brands`: names of successfully processed brands (for logging).
- `stats`: running totals carried through recovery.

### `data/failed_writes.json`

```json
{
  "pending": [
    {
      "tab": "Supplements_Daily",
      "range": "Supplements_Daily!A:O",
      "rows": [["1", "Problem-Solution", ...]],
      "timestamp": "2026-03-12T06:15:00Z",
      "error": "429 Too Many Requests"
    }
  ]
}
```

### Atomic Write Pattern

All JSON file writes use this pattern to prevent corruption:

```elixir
def atomic_write!(path, content) do
  tmp_path = path <> ".tmp"
  File.write!(tmp_path, content)
  File.rename!(tmp_path, path)
end
```

`File.rename!/2` is atomic on the same filesystem (POSIX guarantee).

---

## 8. Sheets Tab Initialization

### Sequence on First Run

`TabInit.ensure_tabs!/1` runs at the start of every pipeline execution:

```
1. GET spreadsheet metadata → list existing tab titles
2. For each required tab NOT in the list:
   a. POST batchUpdate → addSheet
   b. POST values:append → write header row
3. After all tabs exist:
   a. Check if Brand_Config has data rows (> 1 row)
   b. If empty, seed with initial brand data
   c. Check if Discovery_Keywords has data rows
   d. If empty, seed with initial keywords
```

### Required Tabs + Headers

| Tab | Headers |
|-----|---------|
| Brand_Config | brand_name, vertical, meta_library_url, page_id, status, added_date |
| Discovery_Keywords | keyword, vertical, status, last_searched |
| Discovery_Queue | brand_name, vertical, meta_library_url, page_id, discovered_date, keyword_source, status |
| Supplements_Daily | Entry#, Segment Type, Vertical, Format, Principle, Transcript, Why It Works, Source Category, Confidence, Brand/Source Detail, Notes, date_discovered, last_seen, status, ad_id |
| HomeServices_Daily | (same as Supplements_Daily) |
| Daily_Report | date, brands_processed, new_ads_found, ads_decayed, confidence_upgrades, errors, duration_seconds, notes |

### Initial Brand_Config Data

> **Note for Codex:** The page_id values below are placeholders. Before first
> run, Koren must verify each page_id matches the actual Facebook Page ID for
> that brand. The meta_library_url is derived from the page_id.

URL pattern: `https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&view_all_page_id={PAGE_ID}`

**Supplements (9 brands):**

| brand_name | vertical | page_id | status |
|-----------|----------|---------|--------|
| AG1 | supplements | PLACEHOLDER | active |
| Onnit | supplements | PLACEHOLDER | active |
| Momentous | supplements | PLACEHOLDER | active |
| Thorne | supplements | PLACEHOLDER | active |
| Jocko Fuel | supplements | PLACEHOLDER | active |
| Transparent Labs | supplements | PLACEHOLDER | active |
| Legion Athletics | supplements | PLACEHOLDER | active |
| Ryse Supps | supplements | PLACEHOLDER | active |
| Garden of Life | supplements | PLACEHOLDER | active |

**Home Services (9 brands):**

| brand_name | vertical | page_id | status |
|-----------|----------|---------|--------|
| Leaf Filter | home_services | PLACEHOLDER | active |
| Bath Fitter | home_services | PLACEHOLDER | active |
| Renewal by Andersen | home_services | PLACEHOLDER | active |
| Empire Today | home_services | PLACEHOLDER | active |
| Stanley Steemer | home_services | PLACEHOLDER | active |
| ServPro | home_services | PLACEHOLDER | active |
| 1-800-GOT-JUNK | home_services | PLACEHOLDER | active |
| Mr. Rooter | home_services | PLACEHOLDER | active |
| TWO MEN AND A TRUCK | home_services | PLACEHOLDER | active |

**Implementation:** In `TabInit.seed_brand_config!/1`, hardcode these rows as a list of lists. Each row includes `added_date` set to today's date. The `meta_library_url` is constructed from `page_id` at seed time.

**Before first production run:** Koren populates real page_ids in the Sheet manually, or we look them up via a one-time script.

### Initial Discovery_Keywords Data

| keyword | vertical | status |
|---------|----------|--------|
| supplements | supplements | active |
| protein powder | supplements | active |
| pre workout | supplements | active |
| creatine | supplements | active |
| greens powder | supplements | active |
| vitamins | supplements | active |
| nootropics | supplements | active |
| roofing | home_services | active |
| HVAC | home_services | active |
| plumbing | home_services | active |
| gutter guards | home_services | active |
| window replacement | home_services | active |
| pest control | home_services | active |
| lawn care | home_services | active |
| house cleaning | home_services | active |

---

## 9. Mix Task + CLI

### Flag Definitions

| Flag | Type | Default | Behavior |
|------|------|---------|----------|
| `--dry-run` | boolean | false | Execute pipeline but skip all Sheets writes and Slack posts. Print what would be written to stdout. |
| `--brand NAME` | string | nil | Run daily pipeline for a single brand only (must match `brand_name` in Brand_Config exactly). |
| `--recover` | boolean | false | Load checkpoint, resume from last successful brand. |
| `--discover` | boolean | false | Run the weekly discovery pipeline instead of daily. |
| `--verbose` | boolean | false | Log every scraper call, every Claude prompt/response, every Sheets API call. |

### Entry Point Call Chain

```
mix dailyrag --brand "AG1" --verbose
  → Mix.Tasks.Dailyrag.run/1
    → OptionParser.parse(args, switches: @switches)
    → Mix.Task.run("app.start")  # Starts DailyRag.Application → Goth
    → DailyRag.Pipeline.Daily.run(%{brand: "AG1", verbose: true, ...})
      → TabInit.ensure_tabs!/1
      → Checkpoint retry pending writes
      → Sheets.Client.read_range("Brand_Config!A:F")
      → Filter to brand="AG1"
      → Process brand...
```

---

## 10. Cron Commands

### Daily Pipeline — 6 AM MT, every day

Mountain Time = `America/Denver`. 6 AM MT = 13:00 UTC during MST (UTC-7), 12:00 UTC during MDT (UTC-6).

**Using system crontab (recommended):**

```bash
# In crontab -e:
# Runs at 6:00 AM America/Denver every day
CRON_TZ=America/Denver
0 6 * * * cd /Users/q/Projects/dailyrag && /path/to/mix dailyrag 2>&1 >> /Users/q/Projects/dailyrag/data/cron.log
```

**If using `openclaw cron`:**
```bash
openclaw cron add --name "dailyrag-daily" \
  --schedule "0 6 * * *" \
  --timezone "America/Denver" \
  --command "cd /Users/q/Projects/dailyrag && mix dailyrag"

openclaw cron add --name "dailyrag-discovery" \
  --schedule "0 6 * * 0" \
  --timezone "America/Denver" \
  --command "cd /Users/q/Projects/dailyrag && mix dailyrag --discover"
```

### Weekly Discovery — Sundays at 6 AM MT

```bash
CRON_TZ=America/Denver
0 6 * * 0 cd /Users/q/Projects/dailyrag && /path/to/mix dailyrag --discover 2>&1 >> /Users/q/Projects/dailyrag/data/cron.log
```

### Cron Environment Notes
- Cron needs the full path to `mix` (e.g., `/Users/q/.asdf/shims/mix` or equivalent).
- Cron also needs `ANTHROPIC_API_KEY`, `SLACK_BOT_TOKEN`, and Google creds. Either:
  - Source `.env` at the top of the cron script, OR
  - Use `env $(cat .env | xargs)` prefix, OR
  - Set env vars directly in crontab

---

## 11. Environment Setup

### `.env.example`

```bash
# === REQUIRED ===

# Anthropic API key for Claude Sonnet 4.6
ANTHROPIC_API_KEY=sk-ant-...

# Google OAuth2 credentials (from google-oauth.json and google-token.json)
GOOGLE_CLIENT_ID=956604583986-l6j5icb46ar53d85n766eh3kbnpjt65g.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-...
GOOGLE_REFRESH_TOKEN=1//06JDZDm4Bu7x4CgYIARAAGAYSNwF-...

# Slack Bot OAuth Token (needs chat:write scope)
SLACK_BOT_TOKEN=xoxb-...

# === OPTIONAL (have defaults) ===

# Google Sheet ID (default: master sheet from spec)
SHEET_ID=1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0

# Slack channel ID (default: #rag-builder)
SLACK_CHANNEL=C0ALMSS92FK

# Python executable path (default: python3)
PYTHON_PATH=python3
```

### `config/runtime.exs`

```elixir
import Config

config :dailyrag,
  anthropic_api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
  google_client_id: System.fetch_env!("GOOGLE_CLIENT_ID"),
  google_client_secret: System.fetch_env!("GOOGLE_CLIENT_SECRET"),
  google_refresh_token: System.fetch_env!("GOOGLE_REFRESH_TOKEN"),
  slack_bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
  sheet_id: System.get_env("SHEET_ID", "1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0"),
  slack_channel: System.get_env("SLACK_CHANNEL", "C0ALMSS92FK"),
  python_path: System.get_env("PYTHON_PATH", "python3")
```

### How Each Var Is Used

| Variable | Used By | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | `Segmenter` | Auth header for Claude API |
| `GOOGLE_CLIENT_ID` | `Application` (Goth) | OAuth2 token refresh |
| `GOOGLE_CLIENT_SECRET` | `Application` (Goth) | OAuth2 token refresh |
| `GOOGLE_REFRESH_TOKEN` | `Application` (Goth) | OAuth2 token refresh |
| `SLACK_BOT_TOKEN` | `Slack` | Auth header for Slack API |
| `SHEET_ID` | `Sheets.Client` (all calls) | Target spreadsheet |
| `SLACK_CHANNEL` | `Slack` | Target channel for posts |
| `PYTHON_PATH` | `Scraper` | Which python binary to invoke |

---

## 12. Known Risks + Mitigations

### Risk 1: Meta Ad Library DOM/GraphQL Schema Changes

**Impact:** Scraper returns 0 ads for all brands.
**Likelihood:** High (Meta deploys frequently).
**Mitigation:**
- DOM canary detection: if a brand had >5 ads yesterday but 0 today, Slack warning fires immediately.
- If ALL brands return 0 ads, the daily pipeline posts an urgent "Scraper may be broken" alert to Slack.
- GraphQL interception is more stable than DOM parsing (data structure changes less than CSS classes), but still fragile.
- **Response plan:** When this fires, manually inspect the Ad Library page, update the GraphQL parsing logic in `scrape_ads.py`, test with `--brand` flag.

### Risk 2: Google OAuth2 Refresh Token Expiration

**Impact:** All Sheets reads/writes fail.
**Likelihood:** Medium. Google OAuth2 refresh tokens for "Testing" published apps expire after 7 days. For "Production" published apps, they last indefinitely (unless revoked).
**Mitigation:**
- Check the Google Cloud Console project status. If still in "Testing" mode, publish it or add the user as a test user.
- Goth will return a clear error when the refresh token is invalid. The pipeline catches this at the first Sheets call and posts to Slack.
- If the token expires, re-run the OAuth2 flow to get a new refresh token. Store it in `.env`.
- **Long-term fix:** Publish the Google Cloud project to "Production" so refresh tokens don't expire.

### Risk 3: Claude API Rate Limits or Outages

**Impact:** Ad segmentation fails; raw ads are still captured but without analysis.
**Likelihood:** Low-Medium.
**Mitigation:**
- 2x retry with backoff on 429/5xx.
- If Claude is fully down, the pipeline still records ads to Sheets with empty segmentation fields. A follow-up `--recover`-style re-segmentation can be added later.
- Cost estimate: 18 brands × ~10 ads each × ~500 tokens per ad ≈ 90K input tokens per run. Well within rate limits.

### Risk 4: Python Sidecar Environment Issues

**Impact:** Scraper fails to launch.
**Likelihood:** Medium (first-run setup).
**Mitigation:**
- Document exact setup steps: `python3 -m venv priv/scraper/.venv && source priv/scraper/.venv/bin/activate && pip install -r priv/scraper/requirements.txt && scrapling install`
- The `Scraper` module checks for the Python executable and script file on first call. If missing, returns a clear error.
- `PYTHON_PATH` env var allows specifying the venv python path explicitly.
- Consider adding a `mix dailyrag.setup` task that automates venv creation and dependency installation.

### Risk 5: Sheets API Quota Exhaustion

**Impact:** Writes fail mid-pipeline.
**Likelihood:** Low (Google Sheets API allows 300 requests/minute).
**Mitigation:**
- Batch writes where possible (use `values:batchUpdate` for confidence updates and decay status changes).
- `failed_writes.json` caches any writes that fail after retry, so data isn't lost.
- `--recover` retries pending writes on next run.
- If quota is consistently an issue, add a configurable delay between Sheets API calls.

---

## 13. Build Order for Codex

Build each step fully, test it, then move to the next. Steps marked [TEST] have specific test instructions.

- [ ] **Step 1: Initialize Mix project**
  - `mix new dailyrag --sup` inside the repo (or restructure existing files)
  - Set up `mix.exs` with deps from Section 2
  - Create `config/config.exs` (empty) and `config/runtime.exs` (from Section 11)
  - Create `.env.example` (from Section 11)
  - Create `.formatter.exs`: `[inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]`
  - Update `.gitignore`: add `data/`, `.env`, `_build/`, `deps/`, `priv/scraper/.venv/`
  - Run `mix deps.get`
  - [TEST] `mix compile` succeeds

- [ ] **Step 2: DailyRag.Util**
  - Implement `atomic_write!/2`, `ensure_data_dir!/0`, `today/0`, `parse_date/1`
  - [TEST] Write unit tests: atomic write creates file, ensure_data_dir creates directory, date functions return expected formats

- [ ] **Step 3: DailyRag.Dedup**
  - Implement full module per Section 3.8
  - [TEST] Unit tests: load from missing file returns empty, add/known?/filter_new work correctly, save! + load roundtrips

- [ ] **Step 4: DailyRag.Decay**
  - Implement full module per Section 3.9
  - [TEST] Unit tests: diff detects disappeared/new ads, canary_warning? triggers correctly, confidence_upgrades computes correctly for 14d/30d thresholds

- [ ] **Step 5: DailyRag.Checkpoint**
  - Implement full module per Section 3.10
  - [TEST] Unit tests: save/load/clear roundtrip, record_failed_write accumulates, pending_writes returns them

- [ ] **Step 6: DailyRag.Sheets.Client**
  - Implement full module per Section 3.3
  - Do NOT add mocking yet — just the implementation
  - [TEST] Manual test only at this stage: `mix run -e 'DailyRag.Sheets.Client.list_tabs("SHEET_ID")'` with real credentials. Verify it returns tab names.

- [ ] **Step 7: DailyRag.Sheets.Schema**
  - Implement full module per Section 3.5
  - [TEST] Unit tests: header lists have correct lengths, build_daily_row produces 15-element list, parse_brand_config_row roundtrips correctly

- [ ] **Step 8: DailyRag.Sheets.TabInit**
  - Implement full module per Section 3.4, including seed data from Section 8
  - [TEST] Manual test: run against real Sheet. Verify all 6 tabs are created with correct headers. Run again — verify idempotent (no duplicates).

- [ ] **Step 9: Python scraper setup**
  - Create `priv/scraper/requirements.txt`
  - Create `priv/scraper/scrape_ads.py` (from Section 5)
  - Create `priv/scraper/scrape_discovery.py` (from Section 5)
  - [TEST] Manual test: `python3 priv/scraper/scrape_ads.py "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&view_all_page_id=SOME_REAL_PAGE_ID"` — verify JSON output

- [ ] **Step 10: DailyRag.Scraper**
  - Implement full module per Section 3.6
  - [TEST] Manual test: `mix run -e 'DailyRag.Scraper.scrape_ads("URL")'` — verify it returns `{:ok, [%{...}]}` or `{:error, reason}`

- [ ] **Step 11: DailyRag.Segmenter**
  - Implement full module per Section 3.7 + Section 6
  - [TEST] Manual test: call with a few hardcoded ad maps, verify Claude returns valid segments. Also write a unit test that mocks the HTTP call and tests the response parsing logic.

- [ ] **Step 12: DailyRag.Slack**
  - Implement full module per Section 3.11
  - [TEST] Manual test: `mix run -e 'DailyRag.Slack.post("Test message from DailyRag")'` — verify message appears in #rag-builder

- [ ] **Step 13: DailyRag.Pipeline.Daily**
  - Implement full orchestrator per Section 3.12
  - Wire up all modules in the correct sequence
  - [TEST] Run `mix dailyrag --dry-run --brand "AG1" --verbose` (requires Brand_Config to have AG1 with a valid page_id). Verify it scrapes, segments, and prints what would be written.

- [ ] **Step 14: DailyRag.Pipeline.Discovery**
  - Implement full orchestrator per Section 3.13
  - [TEST] Run `mix dailyrag --discover --dry-run --verbose`. Verify it reads keywords, scrapes, and prints discovered brands.

- [ ] **Step 15: Mix.Tasks.Dailyrag**
  - Implement the Mix task per Section 3.15
  - [TEST] `mix dailyrag --help` works. `mix dailyrag --dry-run` runs the full pipeline in dry-run mode.

- [ ] **Step 16: Full integration test**
  - Populate Brand_Config with at least 2 real brands (one per vertical) with valid page_ids
  - Run `mix dailyrag --brand "BRAND_NAME"` (NOT dry-run) against real Sheet
  - Verify: new rows in correct daily tab, dedup index updated, decay cache updated, Daily_Report row added, Slack message posted

- [ ] **Step 17: Recovery test**
  - Manually create a `data/checkpoint.json` with `current_brand_index: 1`
  - Run `mix dailyrag --recover`
  - Verify it skips the first brand and processes from index 1

- [ ] **Step 18: Cron setup**
  - Set up cron entries per Section 10
  - Verify the env vars are available to the cron job
  - Run once manually from cron context to verify

---

*END OF PLAN*
