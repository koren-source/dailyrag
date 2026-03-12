# DailyRag — Ad Creative RAG Enrichment Pipeline

Automated pipeline that scrapes Meta Ad Library daily, segments ad copy with Claude Sonnet 4.6, and builds a structured RAG database in Google Sheets. Tracks ad lifecycle (emergence → decay), discovers new brands weekly, and posts summaries to Slack.

## Architecture

**Elixir-first with Python sidecar.**

- **Elixir** handles: pipeline orchestration, dedup, decay tracking, Claude API calls (segmentation), Google Sheets integration, Slack posting, discovery logic, CLI flags
- **Python** handles: Meta Ad Library browser scraping via Scrapling (~50 lines)
- Elixir calls the Python scraper via a Port, receives raw ad data as JSON, handles all processing

## Setup

### Prerequisites

- Elixir 1.15+
- Python 3.10+
- Google Sheets API credentials (OAuth2)
- Anthropic API key
- Slack Bot token

### Install

```bash
# Elixir deps
mix deps.get

# Python deps
pip3 install -r priv/scraper/requirements.txt

# Playwright browsers (needed for scraper fallback)
python3 -m playwright install
```

### Environment

Copy `.env.example` to `.env` and fill in:

```bash
cp .env.example .env
```

Required variables:
- `ANTHROPIC_API_KEY` — Claude Sonnet 4.6 for ad segmentation
- `GOOGLE_CREDENTIALS_PATH` — Path to Google OAuth2 token JSON
- `GOOGLE_OAUTH_PATH` — Path to Google OAuth2 client credentials
- `SLACK_BOT_TOKEN` — Slack bot token for #rag-builder
- `SLACK_RAG_BUILDER_CHANNEL` — Slack channel ID
- `GOOGLE_SHEET_ID` — Master Google Sheet ID

## Usage

```bash
# Full daily pipeline
mix dailyrag --verbose

# Dry run (scrapes + segments but doesn't write to Sheets)
mix dailyrag --dry-run --verbose

# Single brand only
mix dailyrag --brand "Ghost" --verbose

# Recovery after crash (resumes from checkpoint)
mix dailyrag --recover --verbose

# Weekly brand discovery
mix dailyrag --discover --verbose
```

## CLI Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Run full pipeline but don't write to Sheets or dedup index |
| `--brand NAME` | Run for a single brand only (exact match from Brand_Config) |
| `--recover` | Resume from last successful brand checkpoint |
| `--discover` | Run the weekly brand discovery workflow |
| `--verbose` | Extended logging to stdout |

## Pipeline Flow (Daily)

1. Load active brands from `Brand_Config` sheet
2. For each brand, scrape Meta Ad Library via Python sidecar
3. Dedup against local index — skip already-processed ads
4. Segment new ads with Claude Sonnet 4.6 (hook, body, CTA, offer, etc.)
5. Write segments to `Supplements_Daily` or `HomeServices_Daily` sheet
6. Run confidence promotion (emerging → curated → verified based on ad longevity)
7. Detect decayed ads (ran yesterday but not today) and mark inactive
8. Write daily report row and post Slack summary

## Discovery Flow (Weekly)

1. Read keywords from `Discovery_Keywords` sheet
2. Search Meta Ad Library for each keyword
3. Extract new brand names not in `Brand_Config`
4. Write to `Discovery_Queue` for manual review
5. Auto-promote "approved" entries to `Brand_Config`

## Google Sheets Tabs

| Tab | Purpose |
|-----|---------|
| `Brand_Config` | Active brands with Meta Library URLs |
| `Discovery_Keywords` | Search keywords for weekly discovery |
| `Discovery_Queue` | New brands pending review |
| `Supplements_Daily` | Segmented ad data for supplements vertical |
| `HomeServices_Daily` | Segmented ad data for home services vertical |
| `Daily_Report` | Daily pipeline run statistics |

## Cron Schedule

- **Daily pipeline**: 6 AM MT, every day
- **Weekly discovery**: 6 AM MT, Sundays

See `CRON_SETUP.md` for OpenClaw registration commands.

## Project Structure

```
dailyrag/
├── mix.exs                          # Elixir project config
├── config/config.exs                # Application config
├── lib/
│   ├── dailyrag.ex                  # .env loading
│   └── dailyrag/
│       ├── pipeline.ex              # Main daily pipeline orchestrator
│       ├── discovery.ex             # Weekly brand discovery
│       ├── scraper.ex               # Python Port wrapper
│       ├── dedup.ex                 # Local dedup index (JSON file)
│       ├── decay.ex                 # Decay tracking (JSON cache)
│       ├── segmentation.ex          # Claude Sonnet 4.6 API
│       ├── sheets.ex                # Google Sheets API (OAuth2)
│       └── slack.ex                 # Slack notifications
├── lib/mix/tasks/dailyrag.ex        # Mix task entry point
├── priv/scraper/
│   ├── scrape_ads.py                # Python Scrapling sidecar
│   └── requirements.txt
├── data/                            # Runtime data (gitignored)
│   ├── dedup_index.json
│   ├── decay_cache.json
│   └── checkpoint.json
├── .env.example
├── .gitignore
├── CRON_SETUP.md
└── README.md
```
