from __future__ import annotations

import json
import logging
import threading
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib import error, request

from sqlalchemy.orm import Session

from .db import SessionLocal
from .models import Alarm, AlarmNotification, NotificationChannel
from .observability import NOTIFY_ATTEMPTS_TOTAL, NOTIFY_QUEUE_PENDING

BEIJING_TZ = timezone(timedelta(hours=8))
logger = logging.getLogger("mf.notify")

DEFAULT_NOTIFICATION_CHANNELS = [
    {
        "channel_code": "default_webhook",
        "name": "Default Webhook (disabled)",
        "channel_type": "webhook",
        "enabled": False,
        "retry_max": 3,
        "retry_interval_seconds": 30,
        "timeout_seconds": 5,
        "config_json": {"url": "", "headers": {}},
    }
]


def _now_beijing_naive() -> datetime:
    return datetime.now(BEIJING_TZ).replace(tzinfo=None)


def ensure_default_notification_channels(db: Session) -> None:
    existing_codes = {r.channel_code for r in db.query(NotificationChannel.channel_code).all()}
    created = 0
    for channel in DEFAULT_NOTIFICATION_CHANNELS:
        if channel["channel_code"] in existing_codes:
            continue
        db.add(NotificationChannel(**channel))
        created += 1

    if created > 0:
        db.commit()
        logger.info("notify_channels_bootstrapped", extra={"result": "ok", "created_count": created})


def _build_alarm_payload(alarm: Alarm) -> dict[str, Any]:
    return {
        "alarm_id": alarm.id,
        "rule_code": alarm.rule_code,
        "event_type": alarm.event_type,
        "severity": alarm.severity,
        "status": alarm.status,
        "aibox_id": alarm.aibox_id,
        "cam_id": alarm.cam_id,
        "source_ref": alarm.source_ref,
        "triggered_at": alarm.triggered_at.isoformat() if alarm.triggered_at else None,
        "trigger_value": alarm.trigger_value,
    }


def enqueue_alarm_notifications(alarm_ids: list[int]) -> int:
    alarm_ids = [int(x) for x in alarm_ids if x is not None]
    if not alarm_ids:
        return 0

    db = SessionLocal()
    created = 0
    try:
        channels = (
            db.query(NotificationChannel)
            .filter(NotificationChannel.enabled == True)
            .order_by(NotificationChannel.id.asc())
            .all()
        )
        if not channels:
            return 0

        alarms = db.query(Alarm).filter(Alarm.id.in_(alarm_ids)).all()
        alarm_by_id = {a.id: a for a in alarms}

        now_ts = _now_beijing_naive()
        for alarm_id in alarm_ids:
            alarm = alarm_by_id.get(alarm_id)
            if alarm is None:
                continue
            payload = _build_alarm_payload(alarm)

            for channel in channels:
                exists = (
                    db.query(AlarmNotification.id)
                    .filter(
                        AlarmNotification.alarm_id == alarm.id,
                        AlarmNotification.channel_id == channel.id,
                    )
                    .first()
                )
                if exists is not None:
                    continue

                db.add(
                    AlarmNotification(
                        alarm_id=alarm.id,
                        channel_id=channel.id,
                        channel_code=channel.channel_code,
                        channel_type=channel.channel_type,
                        status="pending",
                        attempts=0,
                        payload_json=payload,
                        next_retry_at=now_ts,
                    )
                )
                created += 1

        if created > 0:
            db.commit()
            logger.info("notify_enqueued", extra={"result": "ok", "created_count": created})
        return created
    except Exception:
        db.rollback()
        logger.exception("notify_enqueue_failed", extra={"result": "failed"})
        return 0
    finally:
        db.close()


def _send_webhook(channel: NotificationChannel, payload: dict[str, Any]) -> tuple[bool, str | None]:
    cfg = channel.config_json or {}
    url = str(cfg.get("url", "")).strip()
    if not url:
        return False, "webhook url is empty"

    headers = {"Content-Type": "application/json"}
    custom_headers = cfg.get("headers", {})
    if isinstance(custom_headers, dict):
        for key, value in custom_headers.items():
            headers[str(key)] = str(value)

    body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
    req = request.Request(url=url, data=body, headers=headers, method="POST")
    timeout = max(int(channel.timeout_seconds or 5), 1)

    try:
        with request.urlopen(req, timeout=timeout) as resp:
            code = getattr(resp, "status", 200)
            if 200 <= int(code) < 300:
                return True, None
            return False, f"http status {code}"
    except error.HTTPError as ex:
        return False, f"http error {ex.code}"
    except Exception as ex:
        return False, str(ex)


def _process_one(db: Session, item: AlarmNotification, now_ts: datetime) -> None:
    channel = db.query(NotificationChannel).filter(NotificationChannel.id == item.channel_id).first()
    if channel is None:
        item.status = "failed"
        item.attempts = int(item.attempts or 0) + 1
        item.last_attempt_at = now_ts
        item.last_error = "channel not found"
        item.next_retry_at = None
        NOTIFY_ATTEMPTS_TOTAL.labels(channel_type=item.channel_type, result="failed").inc()
        return

    if not channel.enabled:
        item.status = "failed"
        item.attempts = int(item.attempts or 0) + 1
        item.last_attempt_at = now_ts
        item.last_error = "channel disabled"
        item.next_retry_at = None
        NOTIFY_ATTEMPTS_TOTAL.labels(channel_type=item.channel_type, result="failed").inc()
        return

    ok = False
    err = "unsupported channel_type"
    if channel.channel_type == "webhook":
        ok, err = _send_webhook(channel, item.payload_json or {})

    item.attempts = int(item.attempts or 0) + 1
    item.last_attempt_at = now_ts

    if ok:
        item.status = "sent"
        item.sent_at = now_ts
        item.last_error = None
        item.next_retry_at = None
        NOTIFY_ATTEMPTS_TOTAL.labels(channel_type=item.channel_type, result="sent").inc()
        logger.info(
            "notify_sent",
            extra={
                "result": "sent",
                "channel_code": item.channel_code,
                "channel_type": item.channel_type,
                "alarm_id": item.alarm_id,
                "notification_id": item.id,
                "attempts": item.attempts,
            },
        )
        return

    retry_max = max(int(channel.retry_max or 1), 1)
    can_retry = item.attempts < retry_max
    item.status = "failed"
    item.last_error = (err or "unknown notify error")[:500]
    if can_retry:
        interval_sec = max(int(channel.retry_interval_seconds or 1), 1)
        item.next_retry_at = now_ts + timedelta(seconds=interval_sec)
    else:
        item.next_retry_at = None

    NOTIFY_ATTEMPTS_TOTAL.labels(channel_type=item.channel_type, result="failed").inc()
    logger.warning(
        "notify_failed",
        extra={
            "result": "failed",
            "channel_code": item.channel_code,
            "channel_type": item.channel_type,
            "alarm_id": item.alarm_id,
            "notification_id": item.id,
            "attempts": item.attempts,
            "reason": item.last_error,
        },
    )


def process_due_notifications(limit: int = 50) -> int:
    db = SessionLocal()
    processed = 0
    try:
        now_ts = _now_beijing_naive()
        pending_items = (
            db.query(AlarmNotification)
            .filter(
                AlarmNotification.status.in_(["pending", "failed"]),
                AlarmNotification.next_retry_at.isnot(None),
                AlarmNotification.next_retry_at <= now_ts,
            )
            .order_by(AlarmNotification.next_retry_at.asc(), AlarmNotification.id.asc())
            .limit(max(int(limit), 1))
            .all()
        )

        for item in pending_items:
            _process_one(db, item, now_ts)
            processed += 1

        db.commit()

        pending_count = (
            db.query(AlarmNotification)
            .filter(
                AlarmNotification.status.in_(["pending", "failed"]),
                AlarmNotification.next_retry_at.isnot(None),
            )
            .count()
        )
        NOTIFY_QUEUE_PENDING.set(float(pending_count))

        return processed
    except Exception:
        db.rollback()
        logger.exception("notify_process_failed", extra={"result": "failed"})
        return 0
    finally:
        db.close()


class NotificationWorker:
    def __init__(self, interval_seconds: int = 2):
        self.interval_seconds = max(int(interval_seconds), 1)
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return

        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, name="notify-worker", daemon=True)
        self._thread.start()
        logger.info("notify_worker_started", extra={"result": "ok", "interval": self.interval_seconds})

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=5)
        logger.info("notify_worker_stopped", extra={"result": "ok"})

    def _run(self) -> None:
        while not self._stop_event.is_set():
            process_due_notifications()
            self._stop_event.wait(self.interval_seconds)
