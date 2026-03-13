import logging

import requests

import config


def _post(message: str) -> None:
    if not config.SLACK_WEBHOOK_URL:
        return

    try:
        response = requests.post(
            config.SLACK_WEBHOOK_URL,
            json={"text": message},
            timeout=10,
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        logging.warning("Slack notification failed: %s", exc)


def alert(message: str) -> None:
    _post(f":warning: {message}")


def notify(message: str) -> None:
    _post(message)
