import os
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
SEEN_ADS_PATH = DATA_DIR / "seen_ads.json"
ROTATION_STATE_PATH = DATA_DIR / "rotation_state.json"
DECAY_LOG_PATH = DATA_DIR / "decay_log.json"
ACTIVE_ADS_SNAPSHOT_PATH = DATA_DIR / "active_ads_snapshot.json"


def _load_dotenv() -> None:
    env_path = BASE_DIR / ".env"
    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


_load_dotenv()

# --- Models ---
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "small")

# --- Timeouts ---
PLAYWRIGHT_PAGE_TIMEOUT = 30_000
VIDEO_DOWNLOAD_TIMEOUT = 60
WHISPER_TIMEOUT = 120
CLAUDE_TIMEOUT = 120
PIPELINE_TIMEOUT = 90 * 60

# --- Concurrency ---
TRANSCRIPTION_WORKERS = int(os.getenv("TRANSCRIPTION_WORKERS", "3"))
SCRAPE_SCROLL_COUNT = int(os.getenv("SCRAPE_SCROLL_COUNT", "5"))
SCRAPE_ADS_LIMIT = int(os.getenv("SCRAPE_ADS_LIMIT", "30"))

# --- Retry ---
CLAUDE_MAX_RETRIES = int(os.getenv("CLAUDE_MAX_RETRIES", "3"))
CLAUDE_RETRY_DELAYS = [2, 5, 10]
CLAUDE_DELAY_BETWEEN_CALLS = int(os.getenv("CLAUDE_DELAY_BETWEEN_CALLS", "1"))

# --- Sheets ---
MASTER_SHEET_ID = os.getenv("GOOGLE_SHEET_ID", "1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0")
BRAND_CONFIG_TAB = "Brand_Config"
SUPPLEMENTS_TAB = "Supplements_Daily"
HOME_SERVICES_TAB = "HomeServices_Daily"
DAILY_REPORT_TAB = "Daily_Report"
GOOGLE_SERVICE_ACCOUNT_PATH = os.getenv(
    "GOOGLE_SERVICE_ACCOUNT_PATH",
    os.getenv("GOOGLE_CREDENTIALS_PATH", ""),
)

# --- Rotation ---
ROTATING_BRAND_COUNT = int(os.getenv("ROTATING_BRAND_COUNT", "3"))

# --- Slack ---
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL", "")

# --- CLI / binaries ---
CLAUDE_BIN = os.getenv("CLAUDE_BIN", "claude")
FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")


def ensure_data_dir() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
