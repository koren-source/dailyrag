import logging
import time
from functools import lru_cache

import gspread
from gspread.exceptions import APIError

import config


_last_write_at = 0.0


@lru_cache(maxsize=1)
def _client() -> gspread.Client:
    if not config.GOOGLE_SERVICE_ACCOUNT_PATH:
        raise RuntimeError("GOOGLE_SERVICE_ACCOUNT_PATH is not configured")

    return gspread.service_account(filename=config.GOOGLE_SERVICE_ACCOUNT_PATH)


@lru_cache(maxsize=1)
def _workbook() -> gspread.Spreadsheet:
    return _client().open_by_key(config.MASTER_SHEET_ID)


def _worksheet(tab_name: str) -> gspread.Worksheet:
    return _workbook().worksheet(tab_name)


def _append_rows_with_retry(worksheet: gspread.Worksheet, rows: list[list[str]]) -> None:
    global _last_write_at

    elapsed = time.time() - _last_write_at
    if elapsed < 1:
        time.sleep(1 - elapsed)

    for attempt in range(2):
        try:
            worksheet.append_rows(rows, value_input_option="USER_ENTERED")
            _last_write_at = time.time()
            return
        except APIError as exc:
            logging.warning("Sheets append failed on attempt %s: %s", attempt + 1, exc)
            if attempt == 1:
                raise
            time.sleep(2)


def _active_flag(value) -> bool:
    return str(value).strip().lower() in {"true", "1", "yes"}


def read_brand_config() -> list[dict]:
    worksheet = _worksheet(config.BRAND_CONFIG_TAB)
    records = worksheet.get_all_records()

    brands = []
    for record in records:
        if not _active_flag(record.get("active")):
            continue

        brands.append(
            {
                "brand_name": str(record.get("brand_name", "")).strip(),
                "vertical": str(record.get("vertical", "")).strip(),
                "search_query": str(record.get("search_query", "")).strip(),
                "ad_library_url": str(record.get("ad_library_url", "")).strip(),
                "active": True,
            }
        )

    return brands


def _tab_for_vertical(vertical: str) -> str:
    if vertical == "dtc-supplements":
        return config.SUPPLEMENTS_TAB
    if vertical == "home-services":
        return config.HOME_SERVICES_TAB
    raise ValueError(f"Unsupported vertical: {vertical}")


def write_segments(segments: list[dict], vertical: str) -> None:
    if not segments:
        return

    worksheet = _worksheet(_tab_for_vertical(vertical))
    existing_rows = worksheet.get_all_values()
    next_entry = max(len(existing_rows), 1)
    rows = []

    for offset, segment in enumerate(segments):
        rows.append(
            [
                str(next_entry + offset),
                segment["segment_type"],
                segment["vertical"],
                segment["format"],
                segment["principle"],
                segment["transcript"],
                segment["why_it_works"],
                segment["source_category"],
                segment["confidence"],
                segment["brand_source_detail"],
                segment["notes"],
            ]
        )

    _append_rows_with_retry(worksheet, rows)


def write_daily_report(stats: dict) -> None:
    worksheet = _worksheet(config.DAILY_REPORT_TAB)
    _append_rows_with_retry(
        worksheet,
        [
            [
                stats.get("run_date", time.strftime("%Y-%m-%d")),
                str(stats.get("brands_scraped", 0)),
                str(stats.get("new_ads_found", 0)),
                str(stats.get("ads_transcribed", 0)),
                str(stats.get("segments_written", 0)),
                str(stats.get("errors", 0)),
                str(stats.get("duration_seconds", 0)),
                stats.get("status", "complete"),
            ]
        ],
    )
