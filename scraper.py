#!/usr/bin/env python3

import argparse
import asyncio
import json
import logging
import random
import re
from datetime import datetime
from typing import Optional
from urllib.parse import quote_plus

from playwright.async_api import BrowserContext, Page, TimeoutError, async_playwright
from playwright_stealth import stealth_async

import config


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


def build_search_url(search_query: str) -> str:
    query = quote_plus(search_query)
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


async def random_pause(min_seconds: float = 0.5, max_seconds: float = 1.5) -> None:
    await asyncio.sleep(random.uniform(min_seconds, max_seconds))


async def dismiss_overlays(page: Page) -> None:
    button_patterns = ["allow all cookies", "accept all", "accept", "close", "not now", "ok"]

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


async def collect_cards(page: Page, limit: int) -> list:
    cards = []

    for selector in CARD_SELECTORS:
        try:
            locator = page.locator(selector)
            count = await locator.count()
            if count <= 0:
                continue

            cards = [locator.nth(index) for index in range(min(count, limit * 2))]
            if cards:
                return cards
        except Exception:
            continue

    return cards


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


async def extract_video_url(card, intercepted_video_urls: list[str]) -> str:
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


async def parse_card(card, intercepted_video_urls: list[str]) -> Optional[dict[str, str]]:
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

        return {
            "ad_id": ad_id,
            "format": "video" if has_video else "static_image",
            "headline": await extract_headline(card),
            "video_url": await extract_video_url(card, intercepted_video_urls) if has_video else "",
            "start_date": parse_started_date(combined),
        }
    except Exception as exc:
        logging.warning("Card parse failed: %s", exc)
        return None


async def scroll_results(page: Page) -> None:
    for _ in range(config.SCRAPE_SCROLL_COUNT):
        await page.mouse.wheel(0, random.randint(1_800, 2_600))
        await asyncio.sleep(random.uniform(1.5, 3.0))


def register_video_interceptor(page: Page, intercepted_video_urls: list[str]) -> None:
    def capture(response) -> None:
        try:
            url = response.url
            content_type = (response.headers.get("content-type") or "").lower()
            if "fbcdn.net" in url and ("video" in content_type or ".mp4" in url):
                intercepted_video_urls.append(url)
        except Exception:
            return

    page.on("response", capture)


async def open_results_page(context: BrowserContext, target_url: str) -> tuple[Page, list[str]]:
    page = await context.new_page()
    await stealth_async(page)
    intercepted_video_urls: list[str] = []
    register_video_interceptor(page, intercepted_video_urls)
    await page.goto(target_url, wait_until="networkidle", timeout=config.PLAYWRIGHT_PAGE_TIMEOUT)
    await random_pause()
    await dismiss_overlays(page)
    await scroll_results(page)
    await dismiss_overlays(page)
    return page, intercepted_video_urls


async def scrape_once(target_url: str, limit: int) -> list[dict[str, str]]:
    async with async_playwright() as playwright:
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
            page, intercepted_video_urls = await open_results_page(context, target_url)
            cards = await collect_cards(page, limit)

            ads: list[dict[str, str]] = []
            seen_ids: set[str] = set()

            for card in cards:
                await random_pause()
                ad = await parse_card(card, intercepted_video_urls)
                if not ad or ad["ad_id"] in seen_ids:
                    continue

                seen_ids.add(ad["ad_id"])
                ads.append(ad)

                if len(ads) >= limit:
                    break

            return ads
        finally:
            await browser.close()


def scrape(brand: dict, limit: int = config.SCRAPE_ADS_LIMIT) -> list[dict[str, str]]:
    target_url = (brand.get("ad_library_url") or "").strip() or build_search_url(
        (brand.get("search_query") or brand.get("brand_name") or "").strip()
    )

    if not target_url:
        logging.warning("No scrape target for brand: %s", brand)
        return []

    for attempt in range(2):
        try:
            return asyncio.run(scrape_once(target_url, max(limit, 1)))
        except TimeoutError:
            logging.warning("Page load timeout for %s on attempt %s", target_url, attempt + 1)
        except Exception as exc:
            logging.warning("Scrape attempt %s failed for %s: %s", attempt + 1, target_url, exc)

    return []


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--brand")
    group.add_argument("--url")
    parser.add_argument("--limit", type=int, default=config.SCRAPE_ADS_LIMIT)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = _parse_args()
    print(
        json.dumps(
            scrape(
                {
                    "brand_name": arguments.brand or "",
                    "search_query": arguments.brand or "",
                    "ad_library_url": arguments.url or "",
                },
                limit=arguments.limit,
            )
        )
    )
