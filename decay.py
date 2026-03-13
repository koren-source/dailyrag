import json
from datetime import date
from typing import Any

import config


def _load_snapshot() -> dict[str, Any]:
    config.ensure_data_dir()

    if not config.ACTIVE_ADS_SNAPSHOT_PATH.exists():
        return {"brands": {}}

    try:
        return json.loads(config.ACTIVE_ADS_SNAPSHOT_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"brands": {}}


def _save_snapshot(snapshot: dict[str, Any]) -> None:
    config.ensure_data_dir()
    config.ACTIVE_ADS_SNAPSHOT_PATH.write_text(
        json.dumps(snapshot, indent=2, sort_keys=True),
        encoding="utf-8",
    )


def _load_decay_log() -> list[dict[str, Any]]:
    config.ensure_data_dir()

    if not config.DECAY_LOG_PATH.exists():
        return []

    try:
        return json.loads(config.DECAY_LOG_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []


def _save_decay_log(entries: list[dict[str, Any]]) -> None:
    config.ensure_data_dir()
    config.DECAY_LOG_PATH.write_text(json.dumps(entries, indent=2, sort_keys=True), encoding="utf-8")


def track(ads: list[dict[str, Any]], brand_name: str) -> list[dict[str, Any]]:
    snapshot = _load_snapshot()
    brands = snapshot.setdefault("brands", {})
    previous = brands.get(brand_name, {"ad_ids": [], "date": None})
    previous_ids = set(previous.get("ad_ids", []))
    today_ids = {str(ad.get("ad_id", "")).strip() for ad in ads if ad.get("ad_id")}
    decayed_ids = sorted(previous_ids - today_ids)
    today = date.today().isoformat()

    if decayed_ids:
        decay_log = _load_decay_log()
        decay_log.extend(
            {
                "brand_name": brand_name,
                "ad_id": ad_id,
                "last_seen_date": previous.get("date"),
                "decayed_on": today,
            }
            for ad_id in decayed_ids
        )
        _save_decay_log(decay_log)

    brands[brand_name] = {"ad_ids": sorted(today_ids), "date": today}
    _save_snapshot(snapshot)

    return [
        {
            "brand_name": brand_name,
            "ad_id": ad_id,
            "last_seen_date": previous.get("date"),
            "decayed_on": today,
        }
        for ad_id in decayed_ids
    ]
