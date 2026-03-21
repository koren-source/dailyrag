# DailyRag — Deployment

## Pipeline Scheduler

DailyRag runs via **macOS launchd** (not an LLM-wrapped cron job).

### Why launchd instead of OpenClaw agentTurn cron?

The pipeline is fully self-sufficient — it posts its own Slack alerts to #rag-builder on success and #q-system-health on failure, and writes its own daily report to Google Sheets. Wrapping it in an LLM session added unnecessary failure modes:
- Model API timeouts could prevent the script from ever running
- Delivery layer failures would mark the job as errored even if the pipeline succeeded
- Verbose stdout could overflow agent message handling

Launchd runs the shell directly. Zero model dependency.

### Setup

1. Copy plist to LaunchAgents:
   ```bash
   cp deploy/ai.openclaw.dailyrag.plist ~/Library/LaunchAgents/
   ```

2. Load it:
   ```bash
   launchctl load ~/Library/LaunchAgents/ai.openclaw.dailyrag.plist
   ```

3. Verify:
   ```bash
   launchctl list | grep dailyrag
   ```

### Schedule

Runs at **2 AM Mountain Time** daily (8 AM UTC during MDT, 9 AM UTC during MST).

> **Note:** launchd uses UTC internally. The plist is set to `Hour: 8` (MDT). During winter (MST/UTC-7), this becomes 3 AM MT. Adjust `Hour` to `9` in winter if exact 2 AM timing matters.

### Manual trigger

```bash
bash scripts/run-dailyrag.sh
```

### Logs

- Runtime log: `~/.openclaw/workspace/memory/dailyrag-exec.log`
- launchd stdout/stderr: `~/.openclaw/workspace/memory/dailyrag-launchd.log`

### Alerts

On failure, the script posts the last 30 lines to #q-system-health (`C0AFX922RJ5`) via `openclaw message send`.
