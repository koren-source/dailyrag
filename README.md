# DailyRag — Pure Python Daily Ad Intelligence Pipeline

DailyRag is a pure Python pipeline that scrapes Meta Ad Library, transcribes video ads with Whisper, segments transcripts through `claude --print`, and writes structured rows into the Cutbox master Google Sheet every morning.

## Stack

- Playwright + `playwright-stealth` for Ad Library scraping
- Whisper `small` for local transcription
- Claude CLI via `claude --print` for transcript segmentation
- `gspread` + Google service account for Sheets I/O
- Slack webhook notifications for failures and completion summaries

## Repo Layout

```text
.
├── main.py
├── config.py
├── scraper.py
├── transcriber.py
├── segmenter.py
├── sheets.py
├── dedup.py
├── decay.py
├── rotation.py
├── slack.py
├── requirements.txt
└── data/                 # runtime JSON state, gitignored
```

## Setup

Requirements:

- Python 3.10+
- `ffmpeg`
- Claude CLI installed and authenticated
- Google service account JSON with edit access to the master sheet

Install:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium
```

Environment:

```bash
cp .env.example .env
```

Set at least:

- `GOOGLE_SERVICE_ACCOUNT_PATH`
- `GOOGLE_SHEET_ID`
- `SLACK_WEBHOOK_URL` if you want notifications

## Run

Full pipeline:

```bash
python3 main.py --verbose
```

Single brand:

```bash
python3 main.py --brand "BuckedUp" --verbose
```

Dry run:

```bash
python3 main.py --dry-run --verbose
```

## Pipeline Flow

1. Read active brands from `Brand_Config`
2. Health-check the scraper against BuckedUp
3. Scrape every active brand and keep only new ads
4. Rotate three brands for full transcription and segmentation
5. Write segments incrementally to the correct daily tab
6. Append a `Daily_Report` row and send Slack notification

## Master Sheet

- Sheet ID: `1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0`
- Read: `Brand_Config`
- Write: `Supplements_Daily`, `HomeServices_Daily`, `Daily_Report`

## Cron

Example:

```bash
0 13 * * * cd /path/to/dailyrag && /usr/bin/python3 main.py >> /var/log/dailyrag.log 2>&1
```
