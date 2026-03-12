# DailyRag Cron Registration

Register these cron jobs with OpenClaw:

## Daily Pipeline — 6 AM MT, Every Day

```bash
openclaw cron add --name "dailyrag-daily" \
  --schedule "0 6 * * *" \
  --timezone "America/Denver" \
  --command "cd /Users/q/Projects/dailyrag && mix dailyrag --verbose"
```

## Weekly Discovery — 6 AM MT, Sundays Only

```bash
openclaw cron add --name "dailyrag-discovery" \
  --schedule "0 6 * * 0" \
  --timezone "America/Denver" \
  --command "cd /Users/q/Projects/dailyrag && mix dailyrag --discover --verbose"
```

## Verify Registration

```bash
openclaw cron list
```

## Manual Run

```bash
# Full pipeline
cd /Users/q/Projects/dailyrag && mix dailyrag --verbose

# Dry run (no writes)
cd /Users/q/Projects/dailyrag && mix dailyrag --dry-run --verbose

# Single brand
cd /Users/q/Projects/dailyrag && mix dailyrag --brand "Ghost" --verbose

# Discovery
cd /Users/q/Projects/dailyrag && mix dailyrag --discover --verbose

# Recovery after crash
cd /Users/q/Projects/dailyrag && mix dailyrag --recover --verbose
```
