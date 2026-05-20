from __future__ import annotations

import json
import logging
import os
import uuid
from datetime import datetime, timedelta, timezone

import paho.mqtt.client as mqtt
from paho.mqtt import publish as mqtt_publish
from pydantic import ValidationError

from .alarm_engine import evaluate_classification, evaluate_device_status, evaluate_speed
from .config import Settings
from .db import SessionLocal
from .device_center import ensure_device_record
from .models import Alarm, DeviceStatus, DisasterData, SpeedData
from .notification_service import enqueue_alarm_notifications
from .observability import MQTT_CONNECTED, MQTT_MESSAGES_TOTAL
from .schemas import ClassificationPayload, DeviceStatusPayload, SpeedPayload

settings = Settings()
BEIJING_TZ = timezone(timedelta(hours=8))
logger = logging.getLogger("mf.mqtt")


def _to_beijing_naive(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value
    return value.astimezone(BEIJING_TZ).replace(tzinfo=None)


def _save_classification(db, topic_aibox_id: str, payload: dict) -> DisasterData:
    data = ClassificationPayload.model_validate(payload)
    aibox_id = data.aibox_id or topic_aibox_id
    ensure_device_record(db, aibox_id, data.cam_id)

    row = DisasterData(
        disaster_id=data.disaster_id,
        aibox_id=aibox_id,
        cam_id=data.cam_id,
        disaster_type=data.disaster_type,
        timestamp=_to_beijing_naive(data.timestamp),
        confidence=data.confidence,
        image_path=data.image_path or data.image_url,
    )
    db.add(row)
    return row


def _save_speed(db, topic_aibox_id: str, payload: dict) -> SpeedData:
    data = SpeedPayload.model_validate(payload)
    aibox_id = data.aibox_id or topic_aibox_id
    ensure_device_record(db, aibox_id, data.cam_id)

    row = SpeedData(
        aibox_id=aibox_id,
        cam_id=data.cam_id,
        disaster_type=data.disaster_type,
        timestamp=_to_beijing_naive(data.timestamp),
        speed=data.speed,
    )
    db.add(row)
    return row


def _upsert_device_status(db, topic_aibox_id: str, payload: dict) -> DeviceStatus:
    data = DeviceStatusPayload.model_validate(payload)
    aibox_id = data.aibox_id or topic_aibox_id
    cam_id = data.cam_id
    ensure_device_record(db, aibox_id, cam_id)

    status = (
        db.query(DeviceStatus)
        .filter(DeviceStatus.aibox_id == aibox_id, DeviceStatus.cam_id == cam_id)
        .first()
    )
    if status is None:
        status = DeviceStatus(aibox_id=aibox_id, cam_id=cam_id)
        db.add(status)

    status.online_status = data.online_status
    status.last_update = _to_beijing_naive(data.timestamp)
    return status


def _topic_type(topic: str) -> str:
    chunks = topic.split("/")
    if len(chunks) < 3:
        return "unknown"
    return chunks[2]


def publish_management_message(topic: str, payload: dict, *, qos: int = 1, retain: bool = False) -> None:
    auth = None
    if settings.mqtt_username:
        auth = {
            "username": settings.mqtt_username,
            "password": settings.mqtt_password,
        }

    mqtt_publish.single(
        topic,
        payload=json.dumps(payload, ensure_ascii=False),
        qos=qos,
        retain=retain,
        hostname=settings.mqtt_broker_host,
        port=settings.mqtt_broker_port,
        auth=auth,
        client_id=f"mf-device-command-{os.getpid()}-{uuid.uuid4().hex[:8]}",
    )


def on_connect(client: mqtt.Client, _userdata, _flags, rc, _properties=None):
    if rc == 0:
        MQTT_CONNECTED.set(1)
        logger.info("mqtt_connected", extra={"client_id": client._client_id.decode(), "rc": str(rc)})
        client.subscribe("disaster_monitoring/+/classification", qos=0)
        client.subscribe("disaster_monitoring/+/speed", qos=0)
        client.subscribe("disaster_monitoring/+/device_status", qos=1)
    else:
        MQTT_CONNECTED.set(0)
        logger.error("mqtt_connect_failed", extra={"client_id": client._client_id.decode(), "rc": str(rc)})


def on_disconnect(client: mqtt.Client, _userdata, disconnect_flags, reason_code, _properties=None):
    MQTT_CONNECTED.set(0)
    logger.warning(
        "mqtt_disconnected",
        extra={
            "client_id": client._client_id.decode(),
            "rc": str(reason_code),
            "result": "disconnected",
        },
    )
    logger.debug("mqtt_disconnect_flags %s", disconnect_flags)


def on_message(_client: mqtt.Client, _userdata, msg: mqtt.MQTTMessage):
    topic = msg.topic
    ttype = _topic_type(topic)

    try:
        payload = json.loads(msg.payload.decode("utf-8"))
    except json.JSONDecodeError:
        MQTT_MESSAGES_TOTAL.labels(topic_type=ttype, result="invalid_json").inc()
        logger.warning("mqtt_invalid_json", extra={"topic": topic, "topic_type": ttype, "result": "invalid_json"})
        return

    chunks = topic.split("/")
    if len(chunks) < 3:
        MQTT_MESSAGES_TOTAL.labels(topic_type="unknown", result="invalid_topic").inc()
        logger.warning("mqtt_invalid_topic", extra={"topic": topic, "topic_type": "unknown", "result": "invalid_topic"})
        return

    topic_aibox_id = chunks[1]
    msg_type = chunks[2]

    db = SessionLocal()
    created_alarms: list[Alarm] = []

    try:
        if msg_type == "classification":
            row = _save_classification(db, topic_aibox_id, payload)
            created_alarms = evaluate_classification(db, row)
        elif msg_type == "speed":
            row = _save_speed(db, topic_aibox_id, payload)
            created_alarms = evaluate_speed(db, row)
        elif msg_type == "device_status":
            row = _upsert_device_status(db, topic_aibox_id, payload)
            created_alarms = evaluate_device_status(db, row)
        else:
            MQTT_MESSAGES_TOTAL.labels(topic_type=msg_type, result="ignored").inc()
            logger.info("mqtt_ignored", extra={"topic": topic, "topic_type": msg_type, "result": "ignored"})
            return

        db.commit()
        MQTT_MESSAGES_TOTAL.labels(topic_type=msg_type, result="ok").inc()

        alarm_ids = [a.id for a in created_alarms if a and a.id is not None]
        if alarm_ids:
            enqueue_alarm_notifications(alarm_ids)
    except ValidationError as ex:
        db.rollback()
        MQTT_MESSAGES_TOTAL.labels(topic_type=msg_type, result="validation_error").inc()
        logger.warning(
            "mqtt_validation_error",
            extra={"topic": topic, "topic_type": msg_type, "result": "validation_error"},
        )
        logger.debug("mqtt_validation_error_detail %s", ex.errors())
    except Exception as ex:
        db.rollback()
        MQTT_MESSAGES_TOTAL.labels(topic_type=msg_type, result="db_error").inc()
        logger.exception(
            "mqtt_db_error",
            extra={"topic": topic, "topic_type": msg_type, "result": "db_error"},
        )
        logger.debug("mqtt_db_error_detail %s", ex)
    finally:
        db.close()


def create_mqtt_client() -> mqtt.Client:
    safe_instance = (settings.app_instance_id or "backend").replace(" ", "-")
    client_id = f"mf-backend-subscriber-{safe_instance}-{os.getpid()}"
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id)

    if settings.mqtt_username:
        client.username_pw_set(settings.mqtt_username, settings.mqtt_password)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    return client
