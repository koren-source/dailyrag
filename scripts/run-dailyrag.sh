#!/usr/bin/env bash
# run-dailyrag.sh — Direct exec wrapper for DailyRag daily pipeline
# No LLM involved. Pipeline handles all Slack alerts internally.
# Triggered by launchd at 2 AM MT daily (replaces agentTurn cron).
#
# Created: 2026-03-21

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROJECT_DIR="/Users/q/Projects/dailyrag"
LOG_FILE="/Users/q/.openclaw/workspace/memory/dailyrag-exec.log"
SYS_HEALTH="C0AFX922RJ5"  # #q-system-health

slack_alert() {
  local msg="$1"
  openclaw message send --channel slack --target "$SYS_HEALTH" -m "$msg" 2>/dev/null || true
}

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DailyRag exec started" | tee -a "$LOG_FILE"

cd "$PROJECT_DIR"

# Pull latest
if ! git pull origin main --ff-only >> "$LOG_FILE" 2>&1; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] git pull failed" | tee -a "$LOG_FILE"
  slack_alert "🚨 DailyRag exec: git pull failed. Check dailyrag-exec.log"
  exit 1
fi

# Compile
if ! mix compile >> "$LOG_FILE" 2>&1; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] mix compile failed" | tee -a "$LOG_FILE"
  slack_alert "🚨 DailyRag exec: mix compile failed. Check dailyrag-exec.log"
  exit 1
fi

# Run pipeline — pipeline posts its own Slack summary to #rag-builder on success/failure
START_TS=$(date +%s)
if mix dailyrag --verbose >> "$LOG_FILE" 2>&1; then
  ELAPSED=$(( $(date +%s) - START_TS ))
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DailyRag completed successfully in ${ELAPSED}s" | tee -a "$LOG_FILE"
else
  EXIT_CODE=$?
  ELAPSED=$(( $(date +%s) - START_TS ))
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] mix dailyrag exited with code $EXIT_CODE after ${ELAPSED}s" | tee -a "$LOG_FILE"
  TAIL=$(tail -30 "$LOG_FILE" | head -c 1800)
  slack_alert "🚨 DailyRag exec failed (exit $EXIT_CODE, ${ELAPSED}s):\n\`\`\`${TAIL}\`\`\`"
  exit $EXIT_CODE
fi
