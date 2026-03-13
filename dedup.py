import json
from typing import Any

import config


def _load_seen_ads() -> dict[str, list[str]]:
    config.ensure_data_dir()

    if not config.SEEN_ADS_PATH.exists():
        return {}

    try:
        return json.loads(config.SEEN_ADS_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def _save_seen_ads(state: dict[str, list[str]]) -> None:
    config.ensure_data_dir()
    config.SEEN_ADS_PATH.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")


def filter_new(ads: list[dict[str, Any]], brand_name: str) -> list[dict[str, Any]]:
    seen_ads = _load_seen_ads()
    known_ids = set(seen_ads.get(brand_name, []))
    return [ad for ad in ads if str(ad.get("ad_id", "")) not in known_ids]


def mark_seen(ads: list[dict[str, Any]], brand_name: str) -> None:
    seen_ads = _load_seen_ads()
    existing = set(seen_ads.get(brand_name, []))

    for ad in ads:
        ad_id = str(ad.get("ad_id", "")).strip()
        if ad_id:
            existing.add(ad_id)

    seen_ads[brand_name] = sorted(existing)
    _save_seen_ads(seen_ads)
