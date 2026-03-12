#!/usr/bin/env python3
"""
Thin Meta Ad Library scraper sidecar.

brand mode output:
[
  {"ad_id": "...", "copy": "...", "start_date": "YYYY-MM-DD"}
]

discovery mode output:
{"html": "<raw search page html>"}
"""

import json
import logging
import random
import re
import sys
import time
from datetime import datetime

logging.basicConfig(stream=sys.stderr, level=logging.WARNING)


def parse_date_string(date_str):
    for fmt in ("%b %d, %Y", "%b %d %Y", "%B %d, %Y", "%B %d %Y"):
        try:
            return datetime.strptime(date_str.strip(), fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    return ""


async def async_scroll_page(page):
    previous_height = 0
    for _ in range(100):
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.wait_for_timeout(random.randint(500, 2000))
        height = await page.evaluate("document.body.scrollHeight")
        if height == previous_height:
            break
        previous_height = height


def scroll_page(page):
    previous_height = 0
    for _ in range(100):
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        time.sleep(random.uniform(0.5, 2.0))
        height = page.evaluate("document.body.scrollHeight")
        if height == previous_height:
            break
        previous_height = height


def extract_page_html(page):
    try:
        if hasattr(page, "html_content"):
            return page.html_content
    except Exception:
        pass
    return str(page)


def extract_brand_ads(html):
    ads = []
    ad_ids = list(dict.fromkeys(re.findall(r"Library\s+ID[:\s]*(\d{8,20})", html, flags=re.I)))

    for ad_id in ad_ids:
        start_date = ""
        copy = ""
        idx = html.find(ad_id)

        if idx >= 0:
            window = html[max(0, idx - 3000) : idx + 3000]
            date_match = re.search(
                r"Started running on\s+([A-Za-z]+\s+\d{1,2},?\s+\d{4})",
                window,
                flags=re.I,
            )
            if date_match:
                start_date = parse_date_string(date_match.group(1))

            clean = re.sub(r"<[^>]+>", " ", window)
            clean = re.sub(r"\s+", " ", clean).strip()
            parts = re.split(r"Library ID|Started running on", clean)
            copy = max((part.strip() for part in parts), key=len, default="")
            copy = copy[:2000]

        ads.append({"ad_id": ad_id, "copy": copy, "start_date": start_date})

    return ads


def fetch_page(url, discovery=False):
    last_error = None

    try:
        from scrapling import StealthyFetcher

        page = StealthyFetcher.fetch(url, headless=True, network_idle=True)
        if not discovery:
            scroll_page(page)
        return extract_page_html(page)
    except Exception as exc:
        last_error = exc

    try:
        from scrapling import PlayWrightFetcher

        page = PlayWrightFetcher.fetch(
            url,
            headless=True,
            page_action=async_scroll_page if not discovery else None,
        )
        return extract_page_html(page)
    except Exception as exc:
        last_error = exc

    raise last_error


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: scrape_ads.py <brand|discovery> <meta_url>"}))
        sys.exit(1)

    mode = sys.argv[1]
    url = sys.argv[2]

    try:
        html = fetch_page(url, discovery=(mode == "discovery"))
    except Exception as exc:
        print(json.dumps({"error": f"Scraping failed: {exc}"}))
        sys.exit(1)

    if mode == "brand":
        print(json.dumps(extract_brand_ads(html)))
        sys.exit(0)

    if mode == "discovery":
        print(json.dumps({"html": html}))
        sys.exit(0)

    print(json.dumps({"error": f"Unknown mode: {mode}"}))
    sys.exit(1)


if __name__ == "__main__":
    main()
