from __future__ import annotations

import json
from datetime import datetime

import paho.mqtt.client as mqtt
from sqlalchemy.orm import Session

from .config import Settings
from .db import SessionLocal
from .models import DeviceStatus, TelemetryData

settings = Settings()


def _parse_event_time(value: str | None) -> datetime:
    if not value:
        return datetime.utcnow()
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return datetime.utcnow()


def _save_telemetry(db: Session, device_code: str, payload: dict):
    event_time = _parse_event_time(payload.get("event_time"))
    trace_id = payload.get("trace_id")

    metrics = payload.get("metrics", [])
    for metric in metrics:
        row = TelemetryData(
            device_code=device_code,
            event_time=event_time,
            metric_key=str(metric.get("key", "unknown")),
            metric_value=float(metric.get("value", 0)),
            unit=metric.get("unit"),
            trace_id=trace_id,
            raw_payload=payload,
        )
        db.add(row)


def _upsert_status(db: Session, device_code: str, payload: dict):
    status = db.query(DeviceStatus).filter(DeviceStatus.device_code == device_code).first()
    if status is None:
        status = DeviceStatus(device_code=device_code)
        db.add(status)

    status.is_online = bool(payload.get("is_online", True))
    status.last_seen_at = _parse_event_time(payload.get("event_time"))
    if payload.get("battery_level") is not None:
        status.battery_level = float(payload["battery_level"])
    if payload.get("signal_strength") is not None:
        status.signal_strength = int(payload["signal_strength"])
    status.raw_payload = payload


def on_connect(client: mqtt.Client, _userdata, _flags, rc, _properties=None):
    if rc == 0:
        print("[MQTT] Connected")
        client.subscribe("mf/+/telemetry", qos=1)
        client.subscribe("mf/+/status", qos=1)
    else:
        print(f"[MQTT] Connect failed, rc={rc}")


def on_message(_client: mqtt.Client, _userdata, msg: mqtt.MQTTMessage):
    topic = msg.topic
    try:
        payload = json.loads(msg.payload.decode("utf-8"))
    except json.JSONDecodeError:
        print(f"[MQTT] Invalid JSON payload topic={topic}")
        return

    chunks = topic.split("/")
    if len(chunks) < 3:
        return

    device_code = chunks[1]
    msg_type = chunks[2]

    db = SessionLocal()
    try:
        if msg_type == "telemetry":
            _save_telemetry(db, device_code, payload)
            _upsert_status(db, device_code, payload)
        elif msg_type == "status":
            _upsert_status(db, device_code, payload)
        db.commit()
    except Exception as ex:
        db.rollback()
        print(f"[MQTT] DB error: {ex}")
    finally:
        db.close()


def create_mqtt_client() -> mqtt.Client:
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="mf-backend-subscriber")

    if settings.mqtt_username:
        client.username_pw_set(settings.mqtt_username, settings.mqtt_password)

    client.on_connect = on_connect
    client.on_message = on_message

    return client
