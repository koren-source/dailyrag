# Cutbox Daily RAG Enrichment Pipeline — PDR v2

**Last updated:** 2026-03-12
**Owner:** Koren (CEO, Cutbox.ai)
**Backend:** Ryan (CTO — Elixir/Phoenix/PostgreSQL)
**Schedule:** Daily at 6:00 AM MT | Discovery: Sundays 6:00 AM MT

---

## Build Plan

**Build tool:** Codex 5.4 (one agent, one codebase, one repo)
**Build model:** Claude Opus 4.6 (`claude-opus-4-6`) — complex architecture, needs strongest model for the build
**Language:** Elixir (primary) + Python sidecar (Scrapling scraping only)
**Output:** Elixir pipeline module + thin Python scraping script, scheduled via OpenClaw cron

### Architecture Decision: Elixir-First with Python Sidecar

The pipeline is Elixir for everything — dedup, decay tracking, Claude API calls for segmentation, Google Sheets integration, Slack posting, discovery logic. The ONLY Python piece is a thin sidecar script (~50 lines) that runs Scrapling for the actual Meta Ad Library browser scraping. Elixir calls it via a Port, receives raw ad data as JSON, and handles all processing. This keeps the codebase inside Ryan's Elixir/Phoenix architecture.

### Repository & Infrastructure

| Item | Value |
|------|-------|
| Repo | `https://github.com/koren-source/dailyrag.git` |
| Slack channel | `#rag-builder` (connector already added — test on first run) |
| Cron registration | OpenClaw cron (managed from OpenClaw interface) |
| API access | Anthropic OAuth subscription (Opus 4.6 + Sonnet 4.6) |
| Google Sheets credentials | Reuse existing OAuth at `/workspace/credentials/google-token.json` and `google-oauth.json` (Sheets API should already be enabled — verify) |
| Master Sheet ID | `1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0` |
| Meta Ad Library URLs | Construct from brand names during setup — Meta's URL format is consistent (`https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=BRANDNAME`) |
| Dedup index + decay cache | Stored in `data/` within the repo as JSON files |
| Recovery checkpoint | Stored in `data/checkpoint.json` |
| Tab creation | Pipeline creates all 6 tabs on first run if they don't exist |

## Runtime Models

| Task | Model | Rationale |
|------|-------|-----------|
| Ad segmentation + "Why It Works" | Claude Sonnet 4.6 (`claude-sonnet-4-6`) | Best cost/quality balance for structured extraction at scale. Upgrade to Opus if week-1 spot-check shows generic output. |
| Weekly brand discovery (parsing search results) | Claude Sonnet 4.6 (`claude-sonnet-4-6`) | Simple extraction task — Sonnet is more than sufficient |

**Model upgrade path:** If Sonnet 4.6 segmentation quality doesn't match the master sheet bar (sharp, specific analysis like "Triple-threat problem callout hits all 3 buyer objections simultaneously" — not generic "Creates urgency"), switch to Opus 4.6 for segmentation. Discovery can stay on Sonnet regardless.

## Timing & SLA

| Event | Expected Time (MT) |
|-------|-------------------|
| Daily pipeline starts | 6:00 AM |
| Scraping complete (18 brands) | ~6:15-6:25 AM |
| Segmentation + Sheets append complete | ~6:30-6:45 AM |
| Daily_Report row + `#rag-builder` notification posted | ~6:30-6:45 AM |
| **SLA: if no Slack post by this time, something broke** | **7:30 AM** |
| Weekly discovery run (Sundays only) | 6:00 AM — completes by ~6:30 AM |

As brand count scales (40+, 80+), scraping time grows linearly. Segmentation parallelizes well. Adjust SLA window if pipeline consistently exceeds 45 minutes.

---

## Purpose

Build and maintain the highest-quality competitive ad intelligence database in supplements and home services. Every dollar a competitor spends on Meta ads generates a data point in our RAG. The pipeline runs daily, captures every new ad, tracks when ads stop running, and feeds structured segments into the master knowledge base.

---

## Architecture Overview

### Daily Pipeline (6 AM MT — runs every day)

```
Brand_Config tab (Google Sheet)
        │
        ▼
   Pipeline Start — Elixir (6 AM MT, OpenClaw cron)
        │
        ├── Read Brand_Config → filter for status = "active"
        │
        ├── For each active brand:
        │     ├── [PYTHON SIDECAR] Scrapling → Meta Ad Library page (Playwright fallback)
        │     ├── Returns JSON: ad copy, Library ID (ad_id), start date
        │     │
        │     ├── [ELIXIR] DEDUP CHECK
        │     │     Compare against local dedup index
        │     │     Skip any ad_id already processed
        │     │
        │     ├── [ELIXIR] NEW ADS → Claude Sonnet 4.6 segmentation
        │     │     Break into: hook / body / CTA / offer / social proof / education / b-roll direction
        │     │     Write "Why It Works" for each segment
        │     │     Auto-assign confidence: 30+ days = verified, 14-29 = curated, 0-13 = emerging
        │     │
        │     ├── [ELIXIR] DECAY CHECK
        │     │     Compare today's active ad_ids vs yesterday's active set
        │     │     Any ad_id missing today → mark status = "inactive", set last_seen = yesterday
        │     │
        │     └── [ELIXIR] Append new rows to Supplements_Daily or HomeServices_Daily
        │
        ├── [ELIXIR] Append row to Daily_Report tab (run summary + counts)
        ├── [ELIXIR] Post daily summary to #rag-builder
        │
        └── Output feeds Ryan's RAG/SQL pipeline
```

### Weekly Discovery Run (Sundays 6 AM MT — finds new brands)

```
Discovery_Keywords tab (Google Sheet)
        │
        ▼
   Discovery Start — Elixir (Sunday 6 AM MT, OpenClaw cron)
        │
        ├── [ELIXIR] Read Discovery_Keywords → all active keywords per vertical
        │
        ├── For each keyword:
        │     ├── [PYTHON SIDECAR] Scrapling → Meta Ad Library SEARCH page
        │     ├── [ELIXIR] Extract brand names + page URLs from results
        │     ├── [ELIXIR] Diff against Brand_Config — skip brands already tracked
        │     │
        │     └── [ELIXIR] NEW brands → append to Discovery_Queue tab
        │           status = "pending", date_found, keyword_source
        │
        ├── [ELIXIR] Post discovery summary to #rag-builder
        │     "Found 12 new brands this week: [list]"
        │
        └── KOREN reviews Discovery_Queue tab
              ├── Flip status to "approved" → auto-added to Brand_Config on next daily run
              └── Flip status to "rejected" → skipped permanently
```

---

## Brand Configuration

Brands are managed via a `Brand_Config` tab in the master Google Sheet. Adding or removing a brand requires zero code changes.

| Column | Type | Description |
|--------|------|-------------|
| brand_name | string | Display name (e.g., "Ghost") |
| vertical | enum | `dtc-supplements` or `home-services` (matches master sheet naming) |
| meta_library_url | URL | Full Meta Ad Library URL for that brand's page |
| status | enum | `active` or `inactive` — pipeline only runs against active brands |
| date_added | date | When the brand was added to tracking |
| source | enum | `manual` (original 18) or `discovery` (found by weekly discovery run) |
| notes | string | Optional — reason for add/pause, etc. |

### Starting Brand List

**Supplements (10):**
BuckedUp, Ghost, Ryse, C4 Energy, Bloom Nutrition, Alani Nu, 1st Phorm, Transparent Labs, Gorilla Mind, Raw Nutrition

**Home Services (8):**
LeafFilter, Renewal by Andersen, TruGreen, SimpliSafe, American Home Shield, Remi Construction, Power Home Remodeling, Trex

### Manual Brand Management

To add a brand: insert a row in Brand_Config with status = `active`. Pipeline picks it up on next run. No deploy, no config file edit.

To pause a brand: flip status to `inactive`. Pipeline skips it. Data already collected is preserved.

---

## Brand Discovery (Weekly)

**Schedule:** Sundays at 6:00 AM MT
**Purpose:** Automatically find new brands spending on Meta ads in both verticals so the pipeline scales without manual research.

### Discovery_Keywords Tab

A list of search terms the discovery run uses to find brands on Meta Ad Library's search interface.

| Column | Type | Description |
|--------|------|-------------|
| keyword | string | Search term (e.g., "pre workout", "roofing contractor") |
| vertical | enum | `dtc-supplements` or `home-services` |
| status | enum | `active` or `inactive` |

**Starting keyword list:**

**Supplements:** pre workout, protein powder, creatine, BCAAs, fat burner, greens powder, collagen supplement, energy drink, sports nutrition, mass gainer, amino acids, multivitamin fitness, post workout recovery

**Home Services:** roofing contractor, gutter installation, window replacement, HVAC repair, lawn care service, home security system, deck builder, solar installation, home warranty, siding replacement, water damage restoration, pest control, garage door repair

Keywords can be added or paused anytime — same pattern as Brand_Config. More keywords = broader net = more brands surfaced.

### Discovery_Queue Tab

Where new brands land after the weekly discovery run. This is Koren's approval inbox.

| Column | Type | Description |
|--------|------|-------------|
| brand_name | string | Brand name found in Meta Ad Library search results |
| vertical | enum | `dtc-supplements` or `home-services` |
| meta_library_url | URL | Direct URL to their Meta Ad Library page |
| keyword_source | string | Which keyword surfaced this brand |
| estimated_ad_count | number | Approximate number of active ads at time of discovery |
| date_found | date | When the discovery run found them |
| status | enum | `pending` / `approved` / `rejected` |

**Approval flow:**
1. Weekly discovery run finds new brands → appends to Discovery_Queue with status = `pending`
2. Koren opens Discovery_Queue tab, reviews new brands
3. For each brand: flip status to `approved` or `rejected`
4. On the next daily pipeline run: any `approved` brand gets auto-copied to Brand_Config with status = `active` and source = `discovery`, then starts getting scraped
5. `rejected` brands are skipped permanently (won't resurface in future discovery runs)

**Why keep Koren in the loop:** Not every brand spending on Meta is worth tracking. A local supplement shop running one ad doesn't generate useful pattern data. The approval step takes 5 minutes per week and keeps data quality high. The `estimated_ad_count` column helps — brands with 10+ active ads are worth tracking, brands with 1-2 probably aren't.

### Expansion Strategy

Go broader in BOTH verticals evenly. The discovery run handles this automatically — keywords cover both supplements and home services, so new brands surface in both categories on every weekly run. Over 2-3 months, the system should scale from 18 brands to 50-100+ with minimal manual effort.

### Dashboard

Deferred. Run the pipeline for 2-3 weeks first. The Daily_Report tab + Slack summary cover operational visibility. Dashboard scope will be defined by whatever questions those two surfaces can't answer after the initial run period. This is purely internal — no customer-facing access planned.

---

## Scraping Layer (Python Sidecar)

**This is the ONLY Python component.** Everything else in the pipeline is Elixir.

**Primary tool:** Scrapling (Python — `pip install scrapling`)
**Fallback:** Playwright (headless Chromium) — used if Scrapling fails on a specific brand
**Integration:** Elixir calls the Python scraper via a Port → receives JSON back → handles all processing in Elixir
**Target:** Meta Ad Library — each brand's page via meta_library_url from Brand_Config
**Cap:** None. Extract ALL active ads visible for each brand.

### Python Sidecar Contract

The Python script accepts a brand URL, scrapes Meta Ad Library, and returns a JSON array:
```json
[
  {"ad_id": "1792148812170796", "copy": "full ad text...", "start_date": "2026-02-15"},
  ...
]
```
That's it. No business logic in Python. Elixir handles dedup, decay, segmentation, Sheets, Slack — everything.

### Why Scrapling Over Raw Playwright
- Cloudflare Turnstile and anti-bot bypass out of the box — Meta Ad Library has bot detection
- Adaptive element tracking survives DOM/page redesigns — solves the biggest fragility risk (Meta changing their page structure)
- TLS fingerprint spoofing + stealth browser built in
- If Scrapling fails on a specific brand page, fall back to raw Playwright for that brand and log a warning

### Extraction Per Ad
- Raw ad copy (full text)
- Library ID → stored as `ad_id`
- Ad start date (if available from Meta)

### Robustness
- Configurable delay between brands (avoid bot detection)
- Randomized scroll timing within each brand's page
- Retry logic: if Scrapling fails → try Playwright fallback → if both fail, retry 2x with backoff → log failure and continue
- **DOM change canary:** If a brand with known active spend returns 0 ads, fire a warning to Slack — likely indicates Meta changed their page structure (Scrapling's adaptive tracking should reduce these incidents)

---

## Dedup System

Local dedup index stores every `ad_id` ever processed.

**On each run:**
1. Pull all active ad_ids from current scrape
2. Check each against dedup index
3. Only NEW ad_ids (not in index) proceed to Claude segmentation
4. After successful processing, add new ad_ids to dedup index

Day 1 for a new brand will be heavy (all existing ads are "new"). Subsequent days capture only genuinely new creative launches.

---

## Decay Tracking

Decay tracking runs as part of every daily scrape — no additional cost.

**Logic:**
1. Load yesterday's active ad_id set per brand (from local cache)
2. Pull today's active ad_id set per brand (from current scrape)
3. Diff: `yesterday_set - today_set` = ads that stopped running
4. For each removed ad_id: update its row → `status = "inactive"`, `last_seen = yesterday's date`
5. Save today's active set as the new cache for tomorrow's comparison

**What this gives you downstream:**
- Ad lifespan calculation: `last_seen - date_discovered` = how long the ad ran
- Kill signals: short-lived ads (< 7 days) likely failed tests
- Fatigue signals: long-running ads (60+ days) that suddenly stop = creative fatigue or seasonal end
- Competitive tempo: how often each brand rotates creative

---

## Claude Segmentation

**Model:** Claude Sonnet 4.6 (`claude-sonnet-4-6`) — see Runtime Models above for upgrade path

For each new ad, send raw copy to Claude with the following extraction prompt:

**Segments to extract (enum allowlist):**
- hook
- body
- CTA
- offer
- social_proof
- education
- b_roll_direction

**For each segment, Claude produces:**
- `Segment Type` — from allowlist above
- `Principle` — the underlying advertising principle at work
- `Transcript` — the actual text of that segment
- `Why It Works` — analysis of why this segment is effective

**Confidence assignment (auto, based on ad runtime):**
- Ad running 30+ days → `verified` — brand is actively spending, this creative is working
- Ad running 14–29 days → `curated` — survived initial testing, likely a performer
- Ad running 0–13 days → `emerging` — too early to judge, could be a test or a winner

Confidence auto-promotes on every run: an ad that crosses the 14-day mark gets upgraded from `emerging` → `curated`, and at 30 days from `curated` → `verified`. Confidence never downgrades.

**Quality control (first week):** Manually spot-check 20-30 entries per day against the master sheet quality bar. The master has sharp, specific analysis (e.g., "Triple-threat problem callout hits all 3 buyer objections simultaneously: taste, efficacy, price"). If the pipeline outputs generic analysis ("Creates urgency"), the Claude prompt needs tuning before running unsupervised.

---

## Google Sheets Structure

**Master Sheet:** `1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0`

The pipeline adds SIX new tabs to the existing master sheet. The existing curated Entries tab (2,330 entries as of March 2026) remains untouched.

| Tab | Purpose | Updated By |
|-----|---------|------------|
| `Brand_Config` | Active brand list — pipeline reads this at start of every run | Koren (manual) + auto from Discovery_Queue approvals |
| `Discovery_Keywords` | Search terms for weekly brand discovery | Koren (manual) |
| `Discovery_Queue` | New brands found by discovery run, awaiting approval | Discovery run (auto) + Koren (approval) |
| `Supplements_Daily` | Daily ad segments for supplement brands | Daily pipeline (auto) |
| `HomeServices_Daily` | Daily ad segments for home services brands | Daily pipeline (auto) |
| `Daily_Report` | One row per run — operational heartbeat | Daily pipeline (auto) |

### Tabs: `Supplements_Daily` and `HomeServices_Daily`

These tabs use the exact same column order as the master Entries tab, plus four pipeline-specific columns appended at the end. This keeps the data compatible with Ryan's existing ingestion logic.

**Columns A–J (matches master sheet exactly):**

| Col | Column Name | Description | Source |
|-----|-------------|-------------|--------|
| A | Entry # | Sequential ID — `SD-XXXX` (supplements) or `HD-XXXX` (home services) | Auto-generated |
| B | Segment Type | From enum allowlist: hook, body, CTA, offer, social_proof, education, b_roll_direction | Claude extraction |
| C | Vertical | `dtc-supplements` or `home-services` (matches master sheet naming) | From Brand_Config |
| D | Format | Ad format if detectable (text-on-screen, talking-head, etc.) — set to `unknown` if not determinable from text copy alone | Claude extraction |
| E | Principle | Advertising principle (problem-callout, stacking, direct-ask, etc.) | Claude extraction |
| F | Transcript | Raw segment text | Claude extraction |
| G | Why It Works | Analysis of why this segment is effective | Claude extraction |
| H | Source Category | Always `ad-library` (matches master sheet convention) | Auto-set |
| I | Confidence | `emerging` (0-13 days) / `curated` (14-29 days) / `verified` (30+ days) | Auto-calculated |
| J | Brand / Source Detail | Brand name + Meta Library ID (e.g., "Ghost / Lib ID 1792148812170796") | From scrape |

**Columns K–O (pipeline-specific, appended after master columns):**

| Col | Column Name | Description | Source |
|-----|-------------|-------------|--------|
| K | Notes | Auto-generated context (campaign details, discovery context) | Auto-generated |
| L | date_discovered | Date the ad was first seen by pipeline (YYYY-MM-DD) | Pipeline |
| M | last_seen | Date the ad was last confirmed active (updated daily) | Pipeline |
| N | status | `active` or `inactive` (set by decay tracking) | Pipeline |
| O | ad_id | Meta Library ID — primary key for dedup and decay | Pipeline |

**Key behaviors:**
- Pipeline ONLY appends new rows. Never edits existing content columns.
- Pipeline DOES update `last_seen`, `status`, and `Confidence` on existing rows during daily checks.
- Entry # sequencing is independent from the master sheet — starts at SD-0001 / HD-0001.
- Confidence auto-promotes: `emerging` → `curated` at 14 days, `curated` → `verified` at 30 days. Never downgrades.
- Columns A–J match the master Entries tab exactly — same names, same order, same conventions.

### Tab: `Daily_Report`

One row per day, appended after each pipeline run. This is the at-a-glance operational log.

| Column | Description | Example |
|--------|-------------|---------|
| Date | Run date | 2026-03-12 |
| Total New Ads | Total new ads captured across all brands | 47 |
| Total Decayed Ads | Total ads that stopped running since yesterday | 14 |
| Supplements New | New ads from supplement brands only | 28 |
| Home Services New | New ads from home services brands only | 19 |
| Supplements Decayed | Decayed ads from supplement brands | 6 |
| Home Services Decayed | Decayed ads from home services brands | 8 |
| Brand Breakdown (New) | Per-brand new ad counts | Ghost (8), Bloom (5), LeafFilter (12) |
| Brand Breakdown (Decayed) | Per-brand decay counts | BuckedUp (3), TruGreen (4) |
| Total Active Tracked | Current count of all active ads across all brands | 412 |
| Total RAG Entries | Cumulative total entries in Supplements_Daily + HomeServices_Daily | 2,847 |
| Errors | Any brand failures, scrape issues, or warnings | none |

**What this gives you:** Open the Daily_Report tab, scroll to the bottom, and in 10 seconds you know: did it run, how much new data, any problems. Over weeks, the rows become a trend line — you'll see brand velocity patterns, seasonal shifts, and database growth rate without building any dashboards.

---

## Daily Summary

**Primary log:** `Daily_Report` tab in the master Google Sheet (one row per run — see schema above).

**Secondary notification:** Post to `#rag-builder` after each run:

```
Daily RAG Update — 2026-03-12
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
New entries: 47
  Ghost (8 new) | Bloom (5 new) | LeafFilter (12 new) | ...

Decayed ads: 14
  BuckedUp (3 stopped) | TruGreen (4 stopped) | ...

Brands with zero new ads: Ryse, SimpliSafe
Brands with zero active ads (⚠️ possible scrape issue): [none]

Total active ads tracked: 412
Total entries in RAG: 2,847
```

The Daily_Report tab is the source of truth. Slack is a notification — if you miss it, the data is always in the sheet.

---

## CLI Flags

| Flag | Purpose |
|------|---------|
| `--dry-run` | Run full pipeline but don't write to Sheets or dedup index |
| `--brand <name>` | Run for a single brand only |
| `--recover` | Resume from last successful brand after a crash |
| `--discover` | Run the weekly brand discovery workflow manually (outside Sunday schedule) |
| `--verbose` | Extended logging |

---

## Failure Handling

- **Single brand failure:** Log error, skip brand, continue with remaining brands. Include in Slack summary.
- **Sheets API failure:** Retry 3x with exponential backoff. If all fail, cache results locally and flag for manual append.
- **Full pipeline crash:** `--recover` flag resumes from the last successful brand checkpoint.
- **Dedup index corruption:** Worst case = some ads get re-processed. Not destructive — just duplicative work that dedup on ad_id in Sheets can catch.

---

## What This Pipeline Does NOT Do

- Does not scrape landing pages (v2 add-on — Cloudflare `/crawl` endpoint is the designated tool for this, one API call returns full site as markdown for RAG ingestion at $5/mo)
- Does not pull ad performance/spend data (not available via Meta Ad Library)
- Does not score ads — scoring happens downstream in Ryan's RAG/SQL system
- Does not run embeddings — embedding happens at ingestion into the RAG vector store

---

## Downstream Integration

All output feeds into Ryan's existing Elixir/Phoenix pipeline:
1. Sheets data → ingested into PostgreSQL
2. Transcripts → embedded via OpenAI text-embedding-3-small
3. Stored in pgvector with HNSW indexing
4. Vertical-filtered scoring: supplements score against supplements only, home services against home services only
5. Consumed by "AI Select" component (planned)
