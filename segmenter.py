#!/usr/bin/env python3

import argparse
import json
import logging
import subprocess
import tempfile
import time
from pathlib import Path

import config


APPROVED_PRINCIPLES = """
Hook: curiosity-gap, pattern-interrupt, bold-claim, problem-callout, social-proof-open, contrarian, question, before-after, urgency, identity-callout
Body: problem-agitate-solve, story-arc, feature-to-benefit, objection-handling, education, demonstration, comparison, stacking
CTA: direct-ask, urgency-scarcity, risk-reversal, next-step-framing, value-recap, social-proof-close
Social Proof: testimonial-result, authority-credential, volume-proof, case-study, user-generated
Education: myth-bust, how-it-works, insider-knowledge, framework-teach, stat-drop
Offer: stack, anchor-discount, urgency-scarcity, risk-reversal, comparison-value
B-roll Direction: proof-of-work, lifestyle-aspiration, problem-visualization, scale-demonstration, environment-context
"""


def determine_confidence(ad: dict) -> str:
    start_date = (ad.get("start_date") or "").strip()
    if not start_date:
        return "curated"

    try:
        started = time.strptime(start_date, "%Y-%m-%d")
        started_ts = time.mktime(started)
        age_days = int((time.time() - started_ts) // 86_400)
        return "verified" if age_days >= 60 else "curated"
    except ValueError:
        return "curated"


def build_notes(ad: dict) -> str:
    return "; ".join(
        [
            f"ad_start_date={ad.get('start_date', '')}",
            f"media_format={ad.get('format', '')}",
            f"copy_source={ad.get('copy_source', '')}",
            f"run_date={time.strftime('%Y-%m-%d')}",
        ]
    )


def build_prompt(ad: dict) -> str:
    return f"""
You are a video ad segmentation expert for Cutbox.ai. Given a video ad transcript, break it into distinct segments and tag each one.

TRANSCRIPT:
"{ad.get('transcript', '')}"

METADATA:
- Brand: {ad.get('brand', '')}
- Vertical: {ad.get('vertical', '')}
- Ad ID: {ad.get('ad_id', '')}
- Ad Start Date: {ad.get('start_date', '')}
- Copy Source: {ad.get('copy_source', '')}

INSTRUCTIONS:
1. Identify each distinct segment in the transcript (hook, body, CTA, education, social-proof, offer, b-roll-direction)
2. A typical video ad has at minimum: one hook + one body + one CTA
3. For each segment, provide ALL of these fields:
   - segment_type: hook | body | cta | education | social-proof | offer | b-roll-direction
   - format: talking-head | voiceover | text-on-screen | ugc | interview | testimonial | demo | mixed
   - principle: 1-3 from the approved list below, comma-separated
   - transcript: the EXACT words from that segment of the ad
   - why_it_works: 1-2 sentences explaining the persuasion technique

APPROVED PRINCIPLES (use ONLY these — do not invent new ones):
{APPROVED_PRINCIPLES}

RESPOND WITH ONLY a JSON array. No markdown fences, no explanation, no preamble. Just the JSON:
[
  {{
    "segment_type": "hook",
    "format": "talking-head",
    "principle": "bold-claim, curiosity-gap",
    "transcript": "I gained 20 pounds of muscle in 90 days and I'm going to show you exactly how.",
    "why_it_works": "Opens with a specific, measurable result that creates both credibility and curiosity about the method."
  }}
]
""".strip()


def _clean_response_text(response_text: str) -> str:
    cleaned = response_text.strip()

    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[1]
        cleaned = cleaned.rsplit("```", 1)[0]

    return cleaned.strip()


def _normalize_string(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    return str(value).strip()


def segment(ad: dict) -> list[dict]:
    if ad.get("copy_source") == "copy_unavailable":
        return []

    prompt = build_prompt(ad)

    for attempt in range(config.CLAUDE_MAX_RETRIES):
        temp_path: Path | None = None

        try:
            with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False, encoding="utf-8") as handle:
                handle.write(prompt)
                handle.flush()
                temp_path = Path(handle.name)

            with temp_path.open("r", encoding="utf-8") as handle:
                result = subprocess.run(
                    [config.CLAUDE_BIN, "--print"],
                    stdin=handle,
                    capture_output=True,
                    text=True,
                    timeout=config.CLAUDE_TIMEOUT,
                    check=False,
                )

            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or "claude --print failed")

            segments = json.loads(_clean_response_text(result.stdout))

            validated = []
            for raw_segment in segments:
                validated.append(
                    {
                        "segment_type": _normalize_string(raw_segment["segment_type"]).lower().replace("_", "-"),
                        "vertical": ad["vertical"],
                        "format": _normalize_string(raw_segment["format"]).lower().replace("_", "-"),
                        "principle": ", ".join(raw_segment["principle"]) if isinstance(raw_segment.get("principle"), list) else _normalize_string(raw_segment.get("principle")),
                        "transcript": _normalize_string(raw_segment["transcript"]),
                        "why_it_works": _normalize_string(raw_segment["why_it_works"]),
                        "source_category": "ad-library",
                        "confidence": determine_confidence(ad),
                        "brand_source_detail": f"{ad['brand']} / ad_{ad['ad_id']}",
                        "notes": build_notes(ad),
                    }
                )

            time.sleep(config.CLAUDE_DELAY_BETWEEN_CALLS)
            return validated
        except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, RuntimeError, Exception) as exc:
            if attempt < config.CLAUDE_MAX_RETRIES - 1:
                time.sleep(config.CLAUDE_RETRY_DELAYS[attempt])
                continue

            logging.error(
                "Segmentation failed for ad %s after %s attempts: %s",
                ad.get("ad_id"),
                config.CLAUDE_MAX_RETRIES,
                exc,
            )
            return []
        finally:
            if temp_path and temp_path.exists():
                temp_path.unlink(missing_ok=True)

    return []


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ad-json", required=True)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = _parse_args()
    print(json.dumps(segment(json.loads(arguments.ad_json))))
