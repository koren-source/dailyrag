#!/usr/bin/env python3

import argparse
import logging
import signal
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import config
import decay
import dedup
import rotation
import scraper
import segmenter
import sheets
import slack
import transcriber


START_TIME = 0.0
CURRENT_PROGRESS = "starting"
CURRENT_STATS = {}
CURRENT_DRY_RUN = False


def _today() -> str:
    return time.strftime("%Y-%m-%d")


def _stats_template() -> dict:
    return {
        "run_date": _today(),
        "brands_scraped": 0,
        "new_ads_found": 0,
        "ads_transcribed": 0,
        "segments_written": 0,
        "errors": 0,
        "duration_seconds": 0,
        "status": "running",
    }


def progress_summary() -> str:
    return CURRENT_PROGRESS


def timeout_handler(_signum, _frame) -> None:
    CURRENT_STATS["duration_seconds"] = int(time.time() - START_TIME)
    CURRENT_STATS["status"] = "timeout"
    message = (
        f"Pipeline timeout after {config.PIPELINE_TIMEOUT // 60} minutes. "
        f"Progress: {progress_summary()}"
    )
    logging.error(message)

    if not CURRENT_DRY_RUN:
        slack.alert(message)
        try:
            sheets.write_daily_report(CURRENT_STATS)
        except Exception as exc:
            logging.error("Failed to write timeout report: %s", exc)

    raise SystemExit(1)


def _configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )


def _apply_headline_fallback(ad: dict, result: dict) -> dict:
    headline = (ad.get("headline") or "").strip()
    ad["transcript"] = headline
    ad["copy_source"] = "headline_fallback" if headline else "copy_unavailable"
    ad["transcription_error"] = result.get("error")
    return ad


def _transcribe_video_ads(video_ads: list[dict]) -> list[dict]:
    if not video_ads:
        return []

    transcribed_ads: list[dict] = []

    with ThreadPoolExecutor(max_workers=config.TRANSCRIPTION_WORKERS) as executor:
        future_map = {
            executor.submit(transcriber.transcribe, ad["ad_id"], ad["video_url"], config.WHISPER_MODEL): ad
            for ad in video_ads
        }

        for future in as_completed(future_map):
            ad = future_map[future]

            try:
                result = future.result()
            except Exception as exc:
                logging.error("Transcription task crashed for %s: %s", ad.get("ad_id"), exc)
                result = {"error": "whisper_failed", "transcript": None, "copy_source": "copy_unavailable"}

            if result.get("error"):
                _apply_headline_fallback(ad, result)
                CURRENT_STATS["errors"] += 1
            else:
                ad["transcript"] = result["transcript"]
                ad["copy_source"] = "whisper_transcript"
                CURRENT_STATS["ads_transcribed"] += 1

            transcribed_ads.append(ad)

    return transcribed_ads


def _abort_run(message: str) -> int:
    logging.error(message)
    CURRENT_STATS["status"] = "aborted"
    CURRENT_STATS["duration_seconds"] = int(time.time() - START_TIME)

    if not CURRENT_DRY_RUN:
        slack.alert(message)
        sheets.write_daily_report(CURRENT_STATS)

    return 1


def run(brand_override: str | None = None, dry_run: bool = False, limit: int | None = None) -> int:
    global START_TIME, CURRENT_PROGRESS, CURRENT_STATS, CURRENT_DRY_RUN

    CURRENT_DRY_RUN = dry_run
    START_TIME = time.time()
    CURRENT_STATS = _stats_template()
    CURRENT_PROGRESS = "loading Brand_Config"
    config.ensure_data_dir()

    signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(config.PIPELINE_TIMEOUT)

    try:
        brands = sheets.read_brand_config()
        if brand_override:
            brands = [brand for brand in brands if brand["brand_name"] == brand_override]
            if not brands:
                raise ValueError(f"Brand not found: {brand_override}")

        CURRENT_PROGRESS = "health check: BuckedUp"
        canary_brand = next((brand for brand in brands if brand["brand_name"] == "BuckedUp"), {
            "brand_name": "BuckedUp",
            "vertical": "dtc-supplements",
            "search_query": "BuckedUp",
            "ad_library_url": "",
            "active": True,
        })
        test_ads = scraper.scrape(canary_brand, limit=5)
        if not test_ads:
            return _abort_run(
                "CRITICAL: Scraper returned 0 results for BuckedUp. Selectors may be broken. Aborting."
            )

        all_new_ads: dict[str, dict] = {}
        CURRENT_PROGRESS = "phase 1: scraping all brands"

        for brand in brands:
            try:
                logging.info("Scraping %s", brand["brand_name"])
                ads = scraper.scrape(brand, limit=limit or config.SCRAPE_ADS_LIMIT)
                new_ads = dedup.filter_new(ads, brand["brand_name"])
                decay.track(ads, brand["brand_name"])
                dedup.mark_seen(new_ads, brand["brand_name"])
                all_new_ads[brand["brand_name"]] = {"brand": brand, "ads": new_ads}
                CURRENT_STATS["brands_scraped"] += 1
                CURRENT_STATS["new_ads_found"] += len(new_ads)
                logging.info(
                    "%s: %s ads scraped, %s new",
                    brand["brand_name"],
                    len(ads),
                    len(new_ads),
                )
            except Exception as exc:
                CURRENT_STATS["errors"] += 1
                logging.error("Brand scrape failed for %s: %s", brand["brand_name"], exc)

        CURRENT_PROGRESS = "phase 2: rotating brands"
        rotating = rotation.get_next(brands)
        logging.info("Rotating brands for full treatment: %s", ", ".join(rotating))

        for brand_name in rotating:
            try:
                if brand_name not in all_new_ads:
                    continue

                brand_data = all_new_ads[brand_name]
                brand = brand_data["brand"]
                video_ads = [
                    {**ad, "brand": brand["brand_name"], "vertical": brand["vertical"]}
                    for ad in brand_data["ads"]
                    if ad.get("format") == "video" and ad.get("video_url")
                ]

                CURRENT_PROGRESS = f"phase 2: transcribing {brand_name}"
                transcribed_ads = _transcribe_video_ads(video_ads)

                CURRENT_PROGRESS = f"phase 2: segmenting {brand_name}"
                for ad in transcribed_ads:
                    segments = segmenter.segment(ad)
                    if not segments:
                        if ad.get("copy_source") != "copy_unavailable":
                            CURRENT_STATS["errors"] += 1
                        continue

                    if dry_run:
                        logging.info("[dry-run] would write %s segments for %s", len(segments), ad["ad_id"])
                    else:
                        try:
                            sheets.write_segments(segments, ad["vertical"])
                        except Exception as exc:
                            CURRENT_STATS["errors"] += 1
                            logging.error("Failed to write segments for %s: %s", ad["ad_id"], exc)
                            continue

                    CURRENT_STATS["segments_written"] += len(segments)
            except Exception as exc:
                CURRENT_STATS["errors"] += 1
                logging.error("Brand processing failed for %s: %s", brand_name, exc)

        CURRENT_STATS["duration_seconds"] = int(time.time() - START_TIME)
        CURRENT_STATS["status"] = "complete"

        if not dry_run:
            sheets.write_daily_report(CURRENT_STATS)
            slack.notify(
                "Pipeline complete: "
                f"{CURRENT_STATS['brands_scraped']} brands scraped, "
                f"{CURRENT_STATS['new_ads_found']} new ads, "
                f"{CURRENT_STATS['ads_transcribed']} transcribed, "
                f"{CURRENT_STATS['segments_written']} segments written in "
                f"{CURRENT_STATS['duration_seconds']}s"
            )

        logging.info("Pipeline complete: %s", CURRENT_STATS)
        return 0
    except SystemExit:
        raise
    except Exception as exc:
        logging.exception("Pipeline failed: %s", exc)
        CURRENT_STATS["errors"] += 1
        CURRENT_STATS["duration_seconds"] = int(time.time() - START_TIME)
        CURRENT_STATS["status"] = "aborted"

        if not dry_run:
            slack.alert(f"Pipeline failed: {exc}")
            try:
                sheets.write_daily_report(CURRENT_STATS)
            except Exception as sheet_exc:
                logging.error("Failed to write aborted report: %s", sheet_exc)

        return 1
    finally:
        signal.alarm(0)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--brand")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    arguments = _parse_args()
    _configure_logging(arguments.verbose)
    sys.exit(run(arguments.brand, arguments.dry_run, arguments.limit))
