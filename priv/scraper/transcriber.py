#!/usr/bin/env python3

import argparse
import asyncio
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import requests


DOWNLOAD_TIMEOUT_SECONDS = 90
MIN_VIDEO_BYTES = 10_000
META_AD_LIBRARY_URL = "https://www.facebook.com/ads/library/?id={ad_id}"
REQUEST_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/136.0.0.0 Safari/537.36"
    ),
    "Referer": "https://www.facebook.com/",
}


class RefreshableTranscriptionError(Exception):
    """Raised when a stale or invalid video download should trigger URL refresh."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ad_id", required=True)
    parser.add_argument("--video_url", required=True)
    parser.add_argument("--model", default="small")
    return parser.parse_args()


def write_stderr(message: str) -> None:
    print(message, file=sys.stderr)


def result(ad_id: str, transcript, copy_source: str, error):
    return {
        "ad_id": ad_id,
        "transcript": transcript,
        "copy_source": copy_source,
        "error": error,
    }


def download_video(url: str, destination: Path) -> None:
    started_at = time.monotonic()

    with requests.get(
        url,
        stream=True,
        timeout=(10, DOWNLOAD_TIMEOUT_SECONDS),
        headers=REQUEST_HEADERS,
    ) as response:
        response.raise_for_status()

        with destination.open("wb") as handle:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if time.monotonic() - started_at > DOWNLOAD_TIMEOUT_SECONDS:
                    raise TimeoutError("download timed out")

                if chunk:
                    handle.write(chunk)


def ensure_download_is_usable(video_path: Path) -> None:
    size = video_path.stat().st_size
    if size < MIN_VIDEO_BYTES:
        raise RefreshableTranscriptionError(
            f"downloaded file too small ({size} bytes) - likely an error page"
        )


async def dismiss_overlays(page) -> None:
    button_patterns = [
        "Allow all cookies",
        "Accept all",
        "Accept",
        "Close",
        "Not now",
        "OK",
    ]

    for pattern in button_patterns:
        try:
            locator = page.locator(
                f'button:has-text("{pattern}"), [role="button"]:has-text("{pattern}")'
            ).first

            if await locator.count() > 0:
                await locator.click(timeout=1_500)
                await asyncio.sleep(0.5)
        except Exception:
            continue

    try:
        await page.keyboard.press("Escape")
    except Exception:
        pass


async def handle_country_selector(page) -> None:
    modal = page.locator(
        'div[role="dialog"]:has-text("Select country"), '
        'div[role="dialog"]:has-text("Select your country")'
    ).first

    try:
        await modal.wait_for(state="visible", timeout=4_000)
    except Exception:
        return

    for locator in [
        modal.get_by_role("button", name="United States").first,
        modal.locator('text=/^United States$/i').first,
        modal.locator('[role="option"]:has-text("United States")').first,
    ]:
        try:
            if await locator.count() > 0:
                await locator.click(timeout=2_000)
                break
        except Exception:
            continue

    await asyncio.sleep(0.5)

    for locator in [
        modal.get_by_role("button", name="Continue").first,
        modal.locator('button:has-text("Continue"), [role="button"]:has-text("Continue")').first,
    ]:
        try:
            if await locator.count() > 0:
                await locator.click(timeout=2_000)
                await asyncio.sleep(1.0)
                return
        except Exception:
            continue


async def refresh_video_url_async(ad_id: str) -> str:
    from playwright.async_api import async_playwright
    from playwright_stealth import Stealth

    lib_url = META_AD_LIBRARY_URL.format(ad_id=ad_id)
    captured_urls = []

    async with Stealth().use_async(async_playwright()) as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            args=["--disable-blink-features=AutomationControlled"],
        )

        try:
            context = await browser.new_context(
                user_agent=REQUEST_HEADERS["User-Agent"],
                locale="en-US",
                timezone_id="America/Denver",
            )
            page = await context.new_page()

            def capture_response(response) -> None:
                try:
                    url = response.url
                    content_type = (response.headers.get("content-type") or "").lower()
                    if "fbcdn.net" in url and ("video" in content_type or ".mp4" in url):
                        captured_urls.append(url)
                except Exception:
                    return

            page.on("response", capture_response)

            await page.goto(lib_url, wait_until="domcontentloaded", timeout=20_000)
            await asyncio.sleep(2.0)
            await dismiss_overlays(page)
            await handle_country_selector(page)
            await dismiss_overlays(page)
            await asyncio.sleep(3.0)

            video = page.locator("video").first
            if await video.count() > 0:
                src = await video.get_attribute("src")
                if src:
                    return src

            if captured_urls:
                return captured_urls[-1]

            return ""
        finally:
            await browser.close()


def refresh_video_url(ad_id: str) -> str:
    try:
        fresh_url = asyncio.run(refresh_video_url_async(ad_id))
    except Exception as exc:
        write_stderr(f"URL refresh failed for {ad_id}: {exc}")
        return ""

    if fresh_url:
        write_stderr(f"Refreshed video URL for ad {ad_id}")

    return fresh_url


def extract_audio(video_path: Path, audio_path: Path) -> None:
    try:
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i",
                str(video_path),
                "-vn",
                "-q:a",
                "0",
                str(audio_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError as exc:
        raise RefreshableTranscriptionError(f"ffmpeg failed: {exc}") from exc


def run_whisper(audio_path: Path, output_dir: Path, model: str) -> Path:
    subprocess.run(
        [
            "whisper",
            str(audio_path),
            "--model",
            model,
            "--language",
            "en",
            "--output_format",
            "txt",
            "--output_dir",
            str(output_dir),
        ],
        check=True,
        timeout=120,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    transcript_path = output_dir / f"{audio_path.stem}.txt"

    if not transcript_path.exists():
        raise FileNotFoundError(f"missing transcript output {transcript_path}")

    return transcript_path


def _run_transcription(ad_id: str, video_url: str, model: str, tmpdir: str) -> dict:
    tmp_path = Path(tmpdir)
    video_path = tmp_path / "ad_video.mp4"
    audio_path = tmp_path / "ad_audio.mp3"

    download_video(video_url, video_path)
    ensure_download_is_usable(video_path)
    extract_audio(video_path, audio_path)
    transcript_path = run_whisper(audio_path, tmp_path, model)
    transcript = transcript_path.read_text(encoding="utf-8").strip()

    if len(transcript.split()) < 5:
        return result(ad_id, None, "copy_unavailable", "empty_transcript")

    return result(ad_id, transcript, "whisper_transcript", None)


def main() -> int:
    args = parse_args()

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            try:
                response = _run_transcription(args.ad_id, args.video_url, args.model, tmpdir)
                print(json.dumps(response))
                return 0
            except (
                requests.RequestException,
                TimeoutError,
                RefreshableTranscriptionError,
            ) as first_exc:
                write_stderr(
                    "First attempt failed "
                    f"({type(first_exc).__name__}: {first_exc}) - refreshing video URL for {args.ad_id}"
                )
                fresh_url = refresh_video_url(args.ad_id)

                if not fresh_url:
                    write_stderr(f"No fresh URL obtained for {args.ad_id}")
                    print(
                        json.dumps(
                            result(args.ad_id, None, "copy_unavailable", "download_failed")
                        )
                    )
                    return 0

                try:
                    response = _run_transcription(args.ad_id, fresh_url, args.model, tmpdir)
                    print(json.dumps(response))
                    return 0
                except Exception as second_exc:
                    write_stderr(f"Retry with fresh URL also failed: {second_exc}")
                    print(
                        json.dumps(
                            result(args.ad_id, None, "copy_unavailable", "download_failed")
                        )
                    )
                    return 0
    except subprocess.TimeoutExpired as exc:
        write_stderr(f"whisper timed out: {exc}")
        print(json.dumps(result(args.ad_id, None, "copy_unavailable", "whisper_failed")))
        return 0
    except subprocess.CalledProcessError as exc:
        write_stderr(f"transcription pipeline failed: {exc}")
        print(json.dumps(result(args.ad_id, None, "copy_unavailable", "whisper_failed")))
        return 0
    except Exception as exc:
        write_stderr(f"unexpected transcription error: {exc}")
        print(json.dumps(result(args.ad_id, None, "copy_unavailable", "whisper_failed")))
        return 0


if __name__ == "__main__":
    sys.exit(main())
