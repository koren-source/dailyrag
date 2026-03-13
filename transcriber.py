#!/usr/bin/env python3

import argparse
import json
import subprocess
import tempfile
import time
from pathlib import Path

import requests

import config


def _result(ad_id: str, transcript, copy_source: str, error):
    return {
        "ad_id": ad_id,
        "transcript": transcript,
        "copy_source": copy_source,
        "error": error,
    }


def _download_video(video_url: str, destination: Path) -> None:
    started_at = time.monotonic()
    headers = {"User-Agent": "Mozilla/5.0"}

    with requests.get(
        video_url,
        stream=True,
        timeout=(10, config.VIDEO_DOWNLOAD_TIMEOUT),
        headers=headers,
    ) as response:
        response.raise_for_status()

        with destination.open("wb") as handle:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if time.monotonic() - started_at > config.VIDEO_DOWNLOAD_TIMEOUT:
                    raise TimeoutError("download timed out")
                if chunk:
                    handle.write(chunk)


def _extract_audio(video_path: Path, audio_path: Path) -> None:
    subprocess.run(
        [
            config.FFMPEG_BIN,
            "-y",
            "-i",
            str(video_path),
            "-q:a",
            "0",
            "-map",
            "a",
            str(audio_path),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _run_whisper(audio_path: Path, output_dir: Path, model: str) -> Path:
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
        timeout=config.WHISPER_TIMEOUT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    transcript_path = output_dir / f"{audio_path.stem}.txt"
    if not transcript_path.exists():
        raise FileNotFoundError(f"Missing transcript output {transcript_path}")
    return transcript_path


def transcribe(ad_id: str, video_url: str, model: str = config.WHISPER_MODEL) -> dict:
    if not video_url:
        return _result(ad_id, None, "copy_unavailable", "download_failed")

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = Path(tmpdir)
            video_path = tmp_path / "ad_video.mp4"
            audio_path = tmp_path / "ad_audio.mp3"

            _download_video(video_url, video_path)
            _extract_audio(video_path, audio_path)
            transcript_path = _run_whisper(audio_path, tmp_path, model)
            transcript = transcript_path.read_text(encoding="utf-8").strip()

            if len(transcript.split()) < 5:
                return _result(ad_id, None, "copy_unavailable", "empty_transcript")

            return _result(ad_id, transcript, "whisper_transcript", None)
    except requests.RequestException:
        return _result(ad_id, None, "copy_unavailable", "download_failed")
    except TimeoutError:
        return _result(ad_id, None, "copy_unavailable", "download_failed")
    except subprocess.TimeoutExpired:
        return _result(ad_id, None, "copy_unavailable", "whisper_failed")
    except subprocess.CalledProcessError:
        return _result(ad_id, None, "copy_unavailable", "whisper_failed")
    except Exception:
        return _result(ad_id, None, "copy_unavailable", "whisper_failed")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ad_id", required=True)
    parser.add_argument("--video_url", required=True)
    parser.add_argument("--model", default=config.WHISPER_MODEL)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = _parse_args()
    print(json.dumps(transcribe(arguments.ad_id, arguments.video_url, arguments.model)))
