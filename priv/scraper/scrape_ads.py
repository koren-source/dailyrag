#!/usr/bin/env python3
"""
Meta Ad Library scraper sidecar.
Input: Meta Ad Library URL (argv[1])
Output: JSON array of ads to stdout
"""

import sys
import json
import time
import random
import re
import logging

# Redirect all logging to stderr so stdout stays clean for JSON output
logging.basicConfig(stream=sys.stderr, level=logging.WARNING)


def scroll_page(page):
    """Scroll page to load all lazy-loaded ads."""
    prev_height = 0
    for _ in range(100):
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        time.sleep(random.uniform(0.5, 2.0))
        new_height = page.evaluate("document.body.scrollHeight")
        if new_height == prev_height:
            break
        prev_height = new_height


async def async_scroll_page(page):
    """Async scroll for PlayWrightFetcher page_action."""
    prev_height = 0
    for _ in range(100):
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.wait_for_timeout(random.randint(500, 2000))
        new_height = await page.evaluate("document.body.scrollHeight")
        if new_height == prev_height:
            break
        prev_height = new_height


def extract_ads_from_page(page):
    """Extract ad data from a loaded Meta Ad Library page."""
    ads = []

    try:
        page_source = page.html_content if hasattr(page, "html_content") else str(page)
    except Exception:
        page_source = str(page)

    # Strategy 1: Find ad cards by looking for Library ID patterns
    # Meta shows "Library ID: XXXXXXXXXXX" in ad cards
    id_matches = re.finditer(
        r"Library\s+ID[:\s]*(\d{10,20})", page_source, re.IGNORECASE
    )
    found_ids = []
    for m in id_matches:
        ad_id = m.group(1)
        if ad_id not in found_ids:
            found_ids.append(ad_id)

    if not found_ids:
        # Strategy 2: Look for ad IDs in URLs
        url_ids = re.findall(r"/ads/library/\?id=(\d+)", page_source)
        found_ids = list(dict.fromkeys(url_ids))

    if not found_ids:
        # Strategy 3: Look for numeric IDs near ad-related content
        potential_ids = re.findall(r'"id"\s*:\s*"(\d{10,20})"', page_source)
        found_ids = list(dict.fromkeys(potential_ids))

    # Extract ad copy and dates using CSS selectors if available
    try:
        ad_cards = page.css("div[class*='_7jvw']") or page.css(
            "div[class*='x1dr75xp']"
        )
        if not ad_cards:
            ad_cards = page.css("div[role='article']") or page.css(
                "div[data-testid]"
            )
    except Exception:
        ad_cards = []

    # Try to extract structured data from cards
    if ad_cards and len(ad_cards) >= len(found_ids):
        for i, card in enumerate(ad_cards):
            ad_id = found_ids[i] if i < len(found_ids) else f"unknown_{i}"
            try:
                text_elements = card.css("div[class*='_4ik4']") or card.css(
                    "span, div > span"
                )
                copy_parts = []
                for el in text_elements:
                    t = el.text.strip() if hasattr(el, "text") else ""
                    if t and len(t) > 10 and "Library ID" not in t:
                        copy_parts.append(t)
                copy = " ".join(copy_parts) if copy_parts else ""
            except Exception:
                copy = ""

            # Extract start date
            start_date = extract_date(card, page_source)

            # Extract page name (advertiser)
            page_name = extract_page_name(card)

            if ad_id and (copy or ad_id != f"unknown_{i}"):
                ads.append(
                    {
                        "ad_id": ad_id,
                        "copy": copy,
                        "start_date": start_date,
                        "page_name": page_name,
                    }
                )
    else:
        # Fallback: create entries from found IDs with text extraction from page source
        for ad_id in found_ids:
            # Try to find copy near the ad_id in the source
            copy = extract_copy_near_id(page_source, ad_id)
            start_date = extract_date_near_id(page_source, ad_id)
            ads.append(
                {
                    "ad_id": ad_id,
                    "copy": copy,
                    "start_date": start_date,
                    "page_name": "",
                }
            )

    return ads


def extract_page_name(card):
    """Try to extract the advertiser/page name from an ad card."""
    try:
        # Page name is usually in a link or strong element at the top of the card
        name_el = card.css("a[href*='facebook.com'] strong") or card.css(
            "a[href*='facebook.com'] span"
        )
        if name_el:
            return name_el[0].text.strip()
        # Try broader selectors
        links = card.css("a")
        for link in links:
            text = link.text.strip() if hasattr(link, "text") else ""
            if text and len(text) > 1 and len(text) < 100:
                return text
    except Exception:
        pass
    return ""


def extract_date(card, page_source):
    """Extract start date from an ad card or nearby text."""
    try:
        text = card.text if hasattr(card, "text") else str(card)
        date_match = re.search(
            r"Started running on\s+(\w+ \d{1,2},?\s*\d{4})", text, re.IGNORECASE
        )
        if date_match:
            return parse_date_string(date_match.group(1))
    except Exception:
        pass
    return ""


def extract_date_near_id(page_source, ad_id):
    """Extract date from page source near an ad ID."""
    idx = page_source.find(ad_id)
    if idx == -1:
        return ""
    # Look in a window around the ID
    window = page_source[max(0, idx - 2000) : idx + 2000]
    date_match = re.search(
        r"Started running on\s+(\w+ \d{1,2},?\s*\d{4})", window, re.IGNORECASE
    )
    if date_match:
        return parse_date_string(date_match.group(1))
    return ""


def extract_copy_near_id(page_source, ad_id):
    """Extract ad copy text from page source near an ad ID."""
    idx = page_source.find(ad_id)
    if idx == -1:
        return ""
    # Look in a window around the ID for substantial text blocks
    window = page_source[max(0, idx - 3000) : idx + 3000]
    # Remove HTML tags
    clean = re.sub(r"<[^>]+>", " ", window)
    clean = re.sub(r"\s+", " ", clean).strip()
    # Find the longest text segment that looks like ad copy
    segments = re.split(r"[|•·]|\bLibrary ID\b|\bStarted running\b", clean)
    best = ""
    for seg in segments:
        seg = seg.strip()
        if len(seg) > len(best) and len(seg) > 20:
            best = seg
    return best[:2000]  # Cap at 2000 chars


def parse_date_string(date_str):
    """Convert 'Feb 15, 2026' to '2026-02-15'."""
    from datetime import datetime

    for fmt in ["%b %d, %Y", "%b %d %Y", "%B %d, %Y", "%B %d %Y"]:
        try:
            dt = datetime.strptime(date_str.strip(), fmt)
            return dt.strftime("%Y-%m-%d")
        except ValueError:
            continue
    return date_str


def scrape_with_stealthy(url, retry=0):
    """Primary: use StealthyFetcher."""
    try:
        from scrapling import StealthyFetcher

        page = StealthyFetcher.fetch(url, headless=True, network_idle=True)
        ads = extract_ads_from_page(page)
        if ads:
            return ads
        if retry < 2:
            time.sleep(2 ** (retry + 1))
            return scrape_with_stealthy(url, retry + 1)
        return []
    except Exception as e:
        if retry < 2:
            time.sleep(2 ** (retry + 1))
            return scrape_with_stealthy(url, retry + 1)
        raise e


def scrape_with_playwright(url, retry=0):
    """Fallback: use PlayWrightFetcher with scrolling."""
    try:
        from scrapling import PlayWrightFetcher

        page = PlayWrightFetcher.fetch(
            url, headless=True, page_action=async_scroll_page
        )
        ads = extract_ads_from_page(page)
        if ads:
            return ads
        if retry < 2:
            time.sleep(2 ** (retry + 1))
            return scrape_with_playwright(url, retry + 1)
        return []
    except Exception as e:
        if retry < 2:
            time.sleep(2 ** (retry + 1))
            return scrape_with_playwright(url, retry + 1)
        raise e


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: scrape_ads.py <meta_ad_library_url>"}))
        sys.exit(1)

    url = sys.argv[1]

    try:
        # Try StealthyFetcher first
        ads = scrape_with_stealthy(url)
        if ads:
            print(json.dumps(ads))
            sys.exit(0)

        # Fallback to PlayWrightFetcher
        ads = scrape_with_playwright(url)
        print(json.dumps(ads))
        sys.exit(0)

    except Exception as e:
        print(json.dumps({"error": f"Scraping failed: {str(e)}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
