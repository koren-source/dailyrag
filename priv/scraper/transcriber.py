#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import requests


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
    headers = {"User-Agent": "Mozilla/5.0"}

    with requests.get(url, stream=True, timeout=(10, 60), headers=headers) as response:
        response.raise_for_status()

        with destination.open("wb") as handle:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if time.monotonic() - started_at > 60:
                    raise TimeoutError("download timed out")

                if chunk:
                    handle.write(chunk)


def extract_audio(video_path: Path, audio_path: Path) -> None:
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


def main() -> int:
    args = parse_args()

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = Path(tmpdir)
            video_path = tmp_path / "ad_video.mp4"
            audio_path = tmp_path / "ad_audio.mp3"

            download_video(args.video_url, video_path)
            extract_audio(video_path, audio_path)
            transcript_path = run_whisper(audio_path, tmp_path, args.model)
            transcript = transcript_path.read_text(encoding="utf-8").strip()

            if len(transcript.split()) < 5:
                print(json.dumps(result(args.ad_id, None, "copy_unavailable", "empty_transcript")))
                return 0

            print(json.dumps(result(args.ad_id, transcript, "whisper_transcript", None)))
            return 0
    except requests.RequestException as exc:
        write_stderr(f"download failed: {exc}")
        print(json.dumps(result(args.ad_id, None, "copy_unavailable", "download_failed")))
        return 0
    except TimeoutError as exc:
        write_stderr(str(exc))
        print(json.dumps(result(args.ad_id, None, "copy_unavailable", "download_failed")))
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
