#!/usr/bin/env python3

import argparse
import asyncio
import json
import logging
import random
import re
import sys
from datetime import datetime
from typing import Dict, List, Optional
from urllib.parse import quote_plus

from playwright.async_api import BrowserContext, Page, TimeoutError, async_playwright
from playwright_stealth import Stealth


logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(message)s")


class InterstitialError(Exception):
    """Raised when the scraper lands on a Facebook login/country wall."""

    pass


USER_AGENTS = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
]

CARD_SELECTORS = [
    '[data-testid="ad-archive-result"]',
    'div[role="article"]',
    'div[xstyle*="boxSizing:border-box"]',
    'div:has-text("Started running on")',
]

HEADLINE_SELECTORS = [
    'div[role="heading"]',
    "h1",
    "h2",
    "h3",
    "strong",
    'div[dir="auto"]',
]

DATE_PATTERNS = [
    "%b %d, %Y",
    "%b %d %Y",
    "%B %d, %Y",
    "%B %d %Y",
]

AD_ID_PATTERNS = [
    r"(?:Library ID|Ad ID|ad_archive_id|adArchiveId|ad_id)[^\d]{0,10}(\d{8,20})",
    r"[?&](?:id|ad_id|ad_archive_id)=(\d{8,20})",
    r"/ads/library/\?id=(\d{8,20})",
    r'"adArchiveID":"(\d{8,20})"',
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--brand")
    group.add_argument("--url")
    parser.add_argument("--limit", type=int, default=30)
    return parser.parse_args()


def build_search_url(brand: str) -> str:
    query = quote_plus(brand)
    return (
        "https://www.facebook.com/ads/library/"
        "?active_status=active"
        "&ad_type=all"
        "&country=US"
        "&is_targeted_country=false"
        "&media_type=all"
        "&search_type=keyword_unordered"
        f"&q={query}"
    )


def parse_started_date(text: str) -> str:
    match = re.search(r"Started running on\s+([A-Za-z]+\s+\d{1,2},?\s+\d{4})", text, re.I)
    if not match:
        return ""

    value = match.group(1).strip()
    for pattern in DATE_PATTERNS:
        try:
            return datetime.strptime(value, pattern).strftime("%Y-%m-%d")
        except ValueError:
            continue

    return ""


def extract_ad_id(text: str) -> str:
    for pattern in AD_ID_PATTERNS:
        match = re.search(pattern, text, re.I)
        if match:
            return match.group(1)

    return ""


async def random_pause(min_seconds: float = 0.5, max_seconds: float = 3.0) -> None:
    await asyncio.sleep(random.uniform(min_seconds, max_seconds))


async def dismiss_overlays(page: Page) -> None:
    button_patterns = [
        "allow all cookies",
        "accept all",
        "accept",
        "close",
        "not now",
        "ok",
    ]

    for pattern in button_patterns:
        try:
            locator = page.locator(
                f'button:has-text("{pattern}"), [role="button"]:has-text("{pattern}")'
            ).first

            if await locator.count() > 0:
                await locator.click(timeout=1_500)
                await random_pause()
        except Exception:
            continue

    try:
        await page.keyboard.press("Escape")
    except Exception:
        pass


async def collect_cards(page: Page, limit: int) -> List:
    seen = []

    for selector in CARD_SELECTORS:
        try:
            locator = page.locator(selector)
            count = await locator.count()

            if count > 0:
                for index in range(min(count, limit * 2)):
                    seen.append(locator.nth(index))

                if seen:
                    return seen
        except Exception:
            continue

    return seen


async def extract_headline(card) -> str:
    for selector in HEADLINE_SELECTORS:
        try:
            locator = card.locator(selector).first
            if await locator.count() == 0:
                continue

            text = " ".join((await locator.all_inner_texts())[:1]).strip()
            if len(text) >= 6:
                return re.sub(r"\s+", " ", text)
        except Exception:
            continue

    try:
        text = await card.inner_text()
        lines = [line.strip() for line in text.splitlines() if len(line.strip()) >= 6]
        return lines[0] if lines else ""
    except Exception:
        return ""


async def extract_video_url(card, intercepted_video_urls: List[str]) -> str:
    try:
        video = card.locator("video").first
        if await video.count() > 0:
            src = await video.get_attribute("src")
            if src:
                return src
    except Exception:
        pass

    for url in reversed(intercepted_video_urls):
        if "fbcdn.net" in url:
            return url

    return ""


async def parse_card(card, intercepted_video_urls: List[str]) -> Optional[Dict[str, str]]:
    try:
        html = await card.inner_html()
        text = re.sub(r"\s+", " ", await card.inner_text())
        combined = f"{html}\n{text}"
        ad_id = extract_ad_id(combined)

        if not ad_id:
            return None

        has_video = False
        try:
            has_video = await card.locator("video").count() > 0
        except Exception:
            has_video = False

        headline = await extract_headline(card)
        INTERSTITIAL_PHRASES = [
            "select country",
            "log in to facebook",
            "log in",
            "you must log in",
            "create new account",
            "sign up for facebook",
            "cookie policy",
            "we use cookies",
        ]
        headline_lower = headline.lower()
        text_lower = text.lower()[:500]
        if any(phrase in headline_lower or phrase in text_lower for phrase in INTERSTITIAL_PHRASES):
            logging.warning(f"Skipping interstitial card: '{headline[:60]}'")
            return None

        start_date = parse_started_date(combined)
        video_url = await extract_video_url(card, intercepted_video_urls) if has_video else ""

        return {
            "ad_id": ad_id,
            "format": "video" if has_video else "static_image",
            "headline": headline,
            "video_url": video_url,
            "start_date": start_date,
        }
    except Exception as exc:
        logging.warning(f"card parse failed: {exc}")
        return None


async def scroll_results(page: Page) -> None:
    for _ in range(random.randint(4, 5)):
        await page.mouse.wheel(0, random.randint(1_800, 2_600))
        await random_pause(1.5, 3.0)


def register_video_interceptor(page: Page, intercepted_video_urls: List[str]) -> None:
    def capture(response) -> None:
        try:
            url = response.url
            headers = response.headers
            content_type = (headers.get("content-type") or "").lower()

            if "fbcdn.net" in url and ("video" in content_type or ".mp4" in url):
                intercepted_video_urls.append(url)
        except Exception:
            return

    page.on("response", capture)


async def open_results_page(context: BrowserContext, target_url: str) -> Page:
    page = await context.new_page()
    # stealth applied via context manager in scrape_once
    intercepted_video_urls: List[str] = []
    register_video_interceptor(page, intercepted_video_urls)
    page._intercepted_video_urls = intercepted_video_urls  # type: ignore[attr-defined]
    await page.goto(target_url, wait_until="networkidle", timeout=30_000)
    await random_pause()
    await dismiss_overlays(page)
    await scroll_results(page)
    await dismiss_overlays(page)
    return page


async def scrape_once(target_url: str, limit: int) -> List[Dict[str, str]]:
    async with Stealth().use_async(async_playwright()) as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            args=["--disable-blink-features=AutomationControlled"],
        )

        try:
            context = await browser.new_context(
                user_agent=random.choice(USER_AGENTS),
                viewport={"width": 1440, "height": 2200},
                locale="en-US",
                timezone_id="America/Denver",
            )

            page = await open_results_page(context, target_url)
            page_text_lower = (await page.inner_text("body"))[:1000].lower()
            FULL_PAGE_INTERSTITIALS = [
                "select your country",
                "log in to continue",
                "you must be logged in",
                "you're not logged in",
                "create new account",
                "log in to facebook",
            ]
            matched = [p for p in FULL_PAGE_INTERSTITIALS if p in page_text_lower]
            if matched:
                logging.warning(f"Landed on interstitial page - matched: {matched}")
                raise InterstitialError(f"Facebook interstitial detected: {matched[0]}")

            cards = await collect_cards(page, limit)
            intercepted_video_urls = getattr(page, "_intercepted_video_urls", [])

            ads: List[Dict[str, str]] = []
            seen_ids = set()

            for card in cards:
                await random_pause()
                ad = await parse_card(card, intercepted_video_urls)

                if not ad:
                    continue

                if ad["ad_id"] in seen_ids:
                    continue

                seen_ids.add(ad["ad_id"])
                ads.append(ad)

                if len(ads) >= limit:
                    break

            return ads
        finally:
            await browser.close()


async def scrape(target_url: str, limit: int) -> List[Dict[str, str]]:
    for attempt in range(2):
        try:
            return await scrape_once(target_url, limit)
        except InterstitialError:
            raise
        except TimeoutError:
            logging.warning(f"page load timeout on attempt {attempt + 1}")
        except Exception as exc:
            logging.warning(f"scrape attempt {attempt + 1} failed: {exc}")

    return []


def main() -> int:
    args = parse_args()
    target_url = args.url or build_search_url(args.brand)
    try:
        ads = asyncio.run(scrape(target_url, max(args.limit, 1)))
        print(json.dumps(ads))
        return 0
    except InterstitialError as exc:
        print(json.dumps({"error": "interstitial", "detail": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
