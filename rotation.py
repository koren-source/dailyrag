import json

import config


def _load_state() -> dict:
    config.ensure_data_dir()

    if not config.ROTATION_STATE_PATH.exists():
        return {"indices": {}, "next_vertical_index": 0}

    try:
        return json.loads(config.ROTATION_STATE_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"indices": {}, "next_vertical_index": 0}


def _save_state(state: dict) -> None:
    config.ensure_data_dir()
    config.ROTATION_STATE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")


def get_next(brands: list[dict], count: int = config.ROTATING_BRAND_COUNT) -> list[str]:
    active_brands = [brand for brand in brands if brand.get("active", True)]
    if not active_brands:
        return []

    grouped: dict[str, list[dict]] = {}
    for brand in active_brands:
        grouped.setdefault(brand["vertical"], []).append(brand)

    verticals = [vertical for vertical in sorted(grouped.keys()) if grouped[vertical]]
    state = _load_state()
    indices = state.setdefault("indices", {})
    start_vertical = state.get("next_vertical_index", 0) % len(verticals)
    selected: list[str] = []
    total_brands = len(active_brands)
    attempts = 0
    cursor = start_vertical

    while len(selected) < min(count, total_brands) and attempts < total_brands * 4:
        vertical = verticals[cursor % len(verticals)]
        brands_in_vertical = grouped[vertical]

        if brands_in_vertical:
            index = indices.get(vertical, 0) % len(brands_in_vertical)
            candidate = brands_in_vertical[index]["brand_name"]
            indices[vertical] = (index + 1) % len(brands_in_vertical)

            if candidate not in selected:
                selected.append(candidate)

        cursor += 1
        attempts += 1

    state["indices"] = indices
    state["next_vertical_index"] = cursor % len(verticals)
    _save_state(state)
    return selected
