from __future__ import annotations

import contextvars
import json
import logging
from datetime import datetime, timezone
from typing import Any

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

REQUEST_ID_CTX: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")


def set_request_id(request_id: str):
    return REQUEST_ID_CTX.set(request_id)


def reset_request_id(token) -> None:
    REQUEST_ID_CTX.reset(token)


def get_request_id() -> str:
    return REQUEST_ID_CTX.get()


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": get_request_id(),
        }

        for key in (
            "path",
            "method",
            "status",
            "duration_ms",
            "ip",
            "key_fp",
            "reason",
            "topic",
            "topic_type",
            "result",
            "client_id",
            "rc",
            "channel_code",
            "channel_type",
            "alarm_id",
            "notification_id",
            "attempts",
            "created",
            "interval",
        ):
            if hasattr(record, key):
                payload[key] = getattr(record, key)

        return json.dumps(payload, ensure_ascii=False, default=str)


def configure_json_logging(level: str = "INFO") -> None:
    root = logging.getLogger()
    root.handlers.clear()

    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())

    root.addHandler(handler)
    root.setLevel(getattr(logging, level.upper(), logging.INFO))


HTTP_REQUESTS_TOTAL = Counter(
    "mf_http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"],
)
HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "mf_http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "path"],
)
HTTP_4XX_TOTAL = Counter(
    "mf_http_4xx_total",
    "Total HTTP 4xx responses",
    ["path"],
)
HTTP_5XX_TOTAL = Counter(
    "mf_http_5xx_total",
    "Total HTTP 5xx responses",
    ["path"],
)

MQTT_CONNECTED = Gauge(
    "mf_mqtt_connected",
    "MQTT connected state (1=connected, 0=disconnected)",
)
MQTT_MESSAGES_TOTAL = Counter(
    "mf_mqtt_messages_total",
    "Total MQTT messages processed",
    ["topic_type", "result"],
)

NOTIFY_ATTEMPTS_TOTAL = Counter(
    "mf_notify_attempts_total",
    "Total external notification attempts",
    ["channel_type", "result"],
)
NOTIFY_QUEUE_PENDING = Gauge(
    "mf_notify_queue_pending",
    "Pending notification queue size",
)


def render_metrics() -> tuple[bytes, str]:
    return generate_latest(), CONTENT_TYPE_LATEST
