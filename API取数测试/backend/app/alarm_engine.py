from __future__ import annotations

import logging
from datetime import datetime, timedelta
from statistics import mean

from sqlalchemy.orm import Session

from .models import Alarm, AlarmRule, DeviceStatus, DisasterData, SpeedData

logger = logging.getLogger("mf.alarm")

DEFAULT_RULES = [
    {
        "rule_code": "cls_high_conf_flood",
        "name": "Flood high confidence",
        "event_type": "classification",
        "severity": "high",
        "enabled": True,
        "cooldown_seconds": 300,
        "condition_json": {"disaster_type": "flood", "min_confidence": 0.9},
    },
    {
        "rule_code": "speed_high_avg",
        "name": "Speed average high",
        "event_type": "speed",
        "severity": "medium",
        "enabled": True,
        "cooldown_seconds": 120,
        "condition_json": {"min_avg_speed": 1.8},
    },
    {
        "rule_code": "device_offline",
        "name": "Device offline",
        "event_type": "device_status",
        "severity": "high",
        "enabled": True,
        "cooldown_seconds": 60,
        "condition_json": {"online_status": "off"},
    },
]


def ensure_default_rules(db: Session) -> None:
    existing_codes = {r.rule_code for r in db.query(AlarmRule.rule_code).all()}
    created = 0
    for rule in DEFAULT_RULES:
        if rule["rule_code"] in existing_codes:
            continue
        db.add(AlarmRule(**rule))
        created += 1
    if created > 0:
        db.commit()
        logger.info("alarm_rules_bootstrapped", extra={"result": "ok", "created_count": created})


def _recent_open_alarm_exists(
    db: Session,
    rule_code: str,
    aibox_id: str,
    cam_id: str,
    now_ts: datetime,
    cooldown_seconds: int,
) -> bool:
    since_ts = now_ts - timedelta(seconds=max(cooldown_seconds, 0))
    item = (
        db.query(Alarm.id)
        .filter(
            Alarm.rule_code == rule_code,
            Alarm.aibox_id == aibox_id,
            Alarm.cam_id == cam_id,
            Alarm.status == "open",
            Alarm.triggered_at >= since_ts,
        )
        .first()
    )
    return item is not None


def _create_alarm(
    db: Session,
    rule: AlarmRule,
    event_type: str,
    aibox_id: str,
    cam_id: str,
    source_ref: str | None,
    trigger_value: dict,
    triggered_at: datetime,
) -> Alarm | None:
    if _recent_open_alarm_exists(db, rule.rule_code, aibox_id, cam_id, triggered_at, rule.cooldown_seconds):
        return None

    alarm = Alarm(
        rule_code=rule.rule_code,
        event_type=event_type,
        severity=rule.severity,
        status="open",
        aibox_id=aibox_id,
        cam_id=cam_id,
        source_ref=source_ref,
        trigger_value=trigger_value,
        triggered_at=triggered_at,
    )
    db.add(alarm)
    db.flush()
    return alarm


def evaluate_classification(db: Session, row: DisasterData) -> list[Alarm]:
    created_alarms: list[Alarm] = []

    rules = (
        db.query(AlarmRule)
        .filter(AlarmRule.enabled == True, AlarmRule.event_type == "classification")
        .all()
    )

    for rule in rules:
        cond = rule.condition_json or {}
        required_type = cond.get("disaster_type")
        min_conf = float(cond.get("min_confidence", 0.0))

        if required_type and row.disaster_type != required_type:
            continue
        if float(row.confidence) < min_conf:
            continue

        alarm = _create_alarm(
            db=db,
            rule=rule,
            event_type="classification",
            aibox_id=row.aibox_id,
            cam_id=row.cam_id,
            source_ref=row.disaster_id,
            trigger_value={
                "disaster_type": row.disaster_type,
                "confidence": float(row.confidence),
            },
            triggered_at=row.timestamp,
        )
        if alarm is not None:
            created_alarms.append(alarm)

    return created_alarms


def evaluate_speed(db: Session, row: SpeedData) -> list[Alarm]:
    if not isinstance(row.speed, list) or not row.speed:
        return []

    created_alarms: list[Alarm] = []

    avg_speed = float(mean(row.speed))
    max_speed = float(max(row.speed))

    rules = (
        db.query(AlarmRule)
        .filter(AlarmRule.enabled == True, AlarmRule.event_type == "speed")
        .all()
    )

    for rule in rules:
        cond = rule.condition_json or {}
        required_type = cond.get("disaster_type")
        min_avg = float(cond.get("min_avg_speed", 0.0))
        min_max = float(cond.get("min_max_speed", 0.0))

        if required_type and row.disaster_type != required_type:
            continue
        if avg_speed < min_avg:
            continue
        if max_speed < min_max:
            continue

        alarm = _create_alarm(
            db=db,
            rule=rule,
            event_type="speed",
            aibox_id=row.aibox_id,
            cam_id=row.cam_id,
            source_ref=None,
            trigger_value={
                "disaster_type": row.disaster_type,
                "avg_speed": avg_speed,
                "max_speed": max_speed,
                "speed": row.speed,
            },
            triggered_at=row.timestamp,
        )
        if alarm is not None:
            created_alarms.append(alarm)

    return created_alarms


def evaluate_device_status(db: Session, row: DeviceStatus) -> list[Alarm]:
    created_alarms: list[Alarm] = []

    rules = (
        db.query(AlarmRule)
        .filter(AlarmRule.enabled == True, AlarmRule.event_type == "device_status")
        .all()
    )

    current_status = row.online_status
    now_ts = row.last_update

    if current_status == "on":
        (
            db.query(Alarm)
            .filter(
                Alarm.event_type == "device_status",
                Alarm.aibox_id == row.aibox_id,
                Alarm.cam_id == row.cam_id,
                Alarm.status.in_(["open", "ack"]),
            )
            .update({"status": "closed", "recovered_at": now_ts}, synchronize_session=False)
        )
        return []

    for rule in rules:
        cond = rule.condition_json or {}
        required_status = cond.get("online_status", "off")
        if current_status != required_status:
            continue

        alarm = _create_alarm(
            db=db,
            rule=rule,
            event_type="device_status",
            aibox_id=row.aibox_id,
            cam_id=row.cam_id,
            source_ref=None,
            trigger_value={"online_status": current_status},
            triggered_at=now_ts,
        )
        if alarm is not None:
            created_alarms.append(alarm)

    return created_alarms
