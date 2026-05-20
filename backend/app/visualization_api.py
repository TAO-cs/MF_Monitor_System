from __future__ import annotations

import csv
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from io import StringIO
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, Query
from fastapi.responses import FileResponse, PlainTextResponse, RedirectResponse, Response
from sqlalchemy import func
from sqlalchemy.orm import Session

from .db import get_db
from .device_api import _require_api_key, _serialize_device_overview
from .models import Alarm, Device, DisasterData, SpeedData

router = APIRouter(tags=["visualization"])

BEIJING_TZ = timezone(timedelta(hours=8))
DASHBOARD_HTML = Path(__file__).resolve().parent / 'dashboard_page.html'
CONSOLE_DIST_CANDIDATES = [
    Path(__file__).resolve().parents[1] / 'frontend_dist',
    Path(__file__).resolve().parents[2] / 'frontend' / 'dist',
]
MAX_WINDOW_HOURS = 24 * 30
MAX_BUCKET_MINUTES = 24 * 60


def _now_beijing() -> datetime:
    return datetime.now(BEIJING_TZ)


def _now_beijing_naive() -> datetime:
    return _now_beijing().replace(tzinfo=None)


def _validate_window(hours: int) -> int:
    if hours < 1 or hours > MAX_WINDOW_HOURS:
        raise ValueError(f"hours must be between 1 and {MAX_WINDOW_HOURS}")
    return hours


def _validate_bucket_minutes(bucket_minutes: int) -> int:
    if bucket_minutes < 1 or bucket_minutes > MAX_BUCKET_MINUTES:
        raise ValueError(f"bucket_minutes must be between 1 and {MAX_BUCKET_MINUTES}")
    return bucket_minutes


def _bucket_start(value: datetime, bucket_minutes: int) -> datetime:
    minute = (value.minute // bucket_minutes) * bucket_minutes
    return value.replace(minute=minute, second=0, microsecond=0)


def _normalize_ts(value: datetime | None) -> str | None:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=BEIJING_TZ)
    else:
        value = value.astimezone(BEIJING_TZ)
    return value.isoformat()


def _build_counts_by_device(rows, field_name: str) -> dict[tuple[str, str], int]:
    data: dict[tuple[str, str], int] = defaultdict(int)
    for row in rows:
        key = (getattr(row, "aibox_id"), getattr(row, "cam_id"))
        data[key] += getattr(row, field_name, 1) if hasattr(row, field_name) else 1
    return data


def _build_summary_payload(db: Session, hours: int) -> dict[str, Any]:
    hours = _validate_window(hours)
    window_start = _now_beijing_naive() - timedelta(hours=hours)

    devices = db.query(Device).order_by(Device.id.asc()).all()
    overview = _serialize_device_overview(db, devices)

    class_rows = (
        db.query(DisasterData.aibox_id, DisasterData.cam_id, DisasterData.disaster_type, DisasterData.timestamp)
        .filter(DisasterData.timestamp >= window_start)
        .all()
    )
    speed_rows = (
        db.query(SpeedData.aibox_id, SpeedData.cam_id, SpeedData.timestamp)
        .filter(SpeedData.timestamp >= window_start)
        .all()
    )
    open_alarm_rows = (
        db.query(Alarm.aibox_id, Alarm.cam_id, Alarm.rule_code)
        .filter(Alarm.status == "open")
        .all()
    )
    latest_alarm_rows = (
        db.query(Alarm)
        .order_by(Alarm.triggered_at.desc(), Alarm.id.desc())
        .limit(12)
        .all()
    )

    class_count_by_device: dict[tuple[str, str], int] = defaultdict(int)
    speed_count_by_device: dict[tuple[str, str], int] = defaultdict(int)
    open_alarm_count_by_device: dict[tuple[str, str], int] = defaultdict(int)
    disaster_mix: dict[str, int] = defaultdict(int)
    hotspot_rules: dict[str, int] = defaultdict(int)

    for row in class_rows:
        key = (row.aibox_id, row.cam_id)
        class_count_by_device[key] += 1
        disaster_mix[row.disaster_type] += 1

    for row in speed_rows:
        key = (row.aibox_id, row.cam_id)
        speed_count_by_device[key] += 1

    for row in open_alarm_rows:
        key = (row.aibox_id, row.cam_id)
        open_alarm_count_by_device[key] += 1
        hotspot_rules[row.rule_code] += 1

    online = 0
    offline = 0
    unknown = 0
    enabled = 0
    disabled = 0
    map_points: list[dict[str, Any]] = []

    for item in overview:
        key = (item["aibox_id"], item["cam_id"])
        status = item.get("status") or {}
        location = item.get("location") or {}
        online_status = status.get("online_status")

        if item.get("enabled"):
            enabled += 1
        else:
            disabled += 1

        if online_status == "on":
            online += 1
        elif online_status == "off":
            offline += 1
        else:
            unknown += 1

        item["classification_count_window"] = class_count_by_device.get(key, 0)
        item["speed_count_window"] = speed_count_by_device.get(key, 0)
        item["open_alarm_count"] = open_alarm_count_by_device.get(key, 0)

        if location:
            map_points.append(
                {
                    "id": item["id"],
                    "aibox_id": item["aibox_id"],
                    "cam_id": item["cam_id"],
                    "label": item.get("device_name") or f'{item["aibox_id"]}-{item["cam_id"]}',
                    "location": location.get("location"),
                    "latitude": location.get("latitude"),
                    "longitude": location.get("longitude"),
                    "online_status": online_status,
                    "enabled": item.get("enabled"),
                    "open_alarm_count": item["open_alarm_count"],
                    "classification_count_window": item["classification_count_window"],
                    "speed_count_window": item["speed_count_window"],
                    "last_update": status.get("last_update"),
                }
            )

    latest_alarms = []
    for row in latest_alarm_rows:
        latest_alarms.append(
            {
                "id": row.id,
                "rule_code": row.rule_code,
                "event_type": row.event_type,
                "severity": row.severity,
                "status": row.status,
                "aibox_id": row.aibox_id,
                "cam_id": row.cam_id,
                "triggered_at": _normalize_ts(row.triggered_at),
                "source_ref": row.source_ref,
            }
        )

    hotspot_list = [
        {"rule_code": key, "count": value}
        for key, value in sorted(hotspot_rules.items(), key=lambda kv: (-kv[1], kv[0]))[:6]
    ]
    disaster_mix_list = [
        {"name": key, "value": value}
        for key, value in sorted(disaster_mix.items(), key=lambda kv: (-kv[1], kv[0]))
    ]

    return {
        "generated_at": _normalize_ts(_now_beijing()),
        "window_hours": hours,
        "cards": {
            "devices_total": len(overview),
            "devices_online": online,
            "devices_offline": offline,
            "devices_unknown": unknown,
            "devices_enabled": enabled,
            "devices_disabled": disabled,
            "open_alarms": len(open_alarm_rows),
            "classification_window": len(class_rows),
            "speed_window": len(speed_rows),
        },
        "devices": overview,
        "map_points": map_points,
        "latest_alarms": latest_alarms,
        "hotspot_rules": hotspot_list,
        "disaster_mix": disaster_mix_list,
    }


def _build_trends_payload(db: Session, hours: int, bucket_minutes: int) -> dict[str, Any]:
    hours = _validate_window(hours)
    bucket_minutes = _validate_bucket_minutes(bucket_minutes)
    window_start = _now_beijing_naive() - timedelta(hours=hours)

    class_rows = db.query(DisasterData.timestamp).filter(DisasterData.timestamp >= window_start).all()
    speed_rows = db.query(SpeedData.timestamp).filter(SpeedData.timestamp >= window_start).all()
    alarm_rows = db.query(Alarm.triggered_at).filter(Alarm.triggered_at >= window_start).all()

    start_bucket = _bucket_start(window_start, bucket_minutes)
    end_time = _now_beijing_naive()

    bucket_map: dict[datetime, dict[str, Any]] = {}
    cursor = start_bucket
    while cursor <= end_time:
        bucket_map[cursor] = {
            "ts": _normalize_ts(cursor),
            "classification_count": 0,
            "speed_count": 0,
            "alarm_count": 0,
        }
        cursor += timedelta(minutes=bucket_minutes)

    for row in class_rows:
        key = _bucket_start(row.timestamp, bucket_minutes)
        bucket_map.setdefault(key, {"ts": _normalize_ts(key), "classification_count": 0, "speed_count": 0, "alarm_count": 0})
        bucket_map[key]["classification_count"] += 1

    for row in speed_rows:
        key = _bucket_start(row.timestamp, bucket_minutes)
        bucket_map.setdefault(key, {"ts": _normalize_ts(key), "classification_count": 0, "speed_count": 0, "alarm_count": 0})
        bucket_map[key]["speed_count"] += 1

    for row in alarm_rows:
        key = _bucket_start(row.triggered_at, bucket_minutes)
        bucket_map.setdefault(key, {"ts": _normalize_ts(key), "classification_count": 0, "speed_count": 0, "alarm_count": 0})
        bucket_map[key]["alarm_count"] += 1

    ordered_keys = sorted(bucket_map.keys())
    return {
        "generated_at": _normalize_ts(_now_beijing()),
        "window_hours": hours,
        "bucket_minutes": bucket_minutes,
        "buckets": [bucket_map[key] for key in ordered_keys],
    }



def _console_dist() -> Path:
    for candidate in CONSOLE_DIST_CANDIDATES:
        if candidate.exists():
            return candidate
    return CONSOLE_DIST_CANDIDATES[0]


def _resolve_console_asset(asset_path: str | None) -> Path | None:
    if not asset_path:
        return None
    dist_dir = _console_dist()
    index_path = dist_dir / "index.html"
    try:
        target = (dist_dir / asset_path).resolve()
    except OSError:
        return None
    if not index_path.exists():
        return None
    if dist_dir.resolve() not in target.parents and target != dist_dir.resolve():
        return None
    if target.is_file():
        return target
    return None
def _build_report_csv(db: Session, hours: int) -> str:
    summary = _build_summary_payload(db, hours)
    output = StringIO()
    writer = csv.writer(output)
    writer.writerow([
        "aibox_id",
        "cam_id",
        "device_name",
        "device_type",
        "enabled",
        "online_status",
        "location",
        "latitude",
        "longitude",
        "open_alarm_count",
        "classification_count_window",
        "speed_count_window",
        "last_update",
    ])

    for item in summary["devices"]:
        location = item.get("location") or {}
        status = item.get("status") or {}
        writer.writerow([
            item.get("aibox_id"),
            item.get("cam_id"),
            item.get("device_name"),
            item.get("device_type"),
            item.get("enabled"),
            status.get("online_status"),
            location.get("location"),
            location.get("latitude"),
            location.get("longitude"),
            item.get("open_alarm_count", 0),
            item.get("classification_count_window", 0),
            item.get("speed_count_window", 0),
            status.get("last_update"),
        ])

    return output.getvalue()


@router.get("/dashboard")
def dashboard_page():
    return FileResponse(DASHBOARD_HTML)


@router.get("/")
def root_page():
    return RedirectResponse(url="/monitor/", status_code=302)


@router.get("/monitor")
@router.get("/monitor/")
def monitor_page():
    index_path = _console_dist() / "index.html"
    if not index_path.exists():
        return PlainTextResponse(
            "Vue frontend build not found. Run scripts/build_frontend.ps1 first.",
            status_code=503,
        )
    return FileResponse(index_path)


@router.get("/console")
@router.get("/console/")
def console_page():
    return RedirectResponse(url="/monitor/", status_code=302)


@router.get("/monitor/{asset_path:path}")
def monitor_assets(asset_path: str):
    asset = _resolve_console_asset(asset_path)
    if asset is not None:
        return FileResponse(asset)

    index_path = _console_dist() / "index.html"
    if index_path.exists():
        return FileResponse(index_path)

    return PlainTextResponse(
        "Vue frontend build not found. Run scripts/build_frontend.ps1 first.",
        status_code=503,
    )


@router.get("/console/{asset_path:path}")
def console_assets(asset_path: str):
    return RedirectResponse(url=f"/monitor/{asset_path}", status_code=302)


@router.get("/api/dashboard/summary", dependencies=[Depends(_require_api_key)])
def api_dashboard_summary(
    hours: int = Query(default=24, ge=1, le=MAX_WINDOW_HOURS),
    db: Session = Depends(get_db),
):
    return _build_summary_payload(db, hours)


@router.get("/api/dashboard/trends", dependencies=[Depends(_require_api_key)])
def api_dashboard_trends(
    hours: int = Query(default=24, ge=1, le=MAX_WINDOW_HOURS),
    bucket_minutes: int = Query(default=60, ge=1, le=MAX_BUCKET_MINUTES),
    db: Session = Depends(get_db),
):
    return _build_trends_payload(db, hours, bucket_minutes)


@router.get("/api/dashboard/report.csv", dependencies=[Depends(_require_api_key)])
def api_dashboard_report(
    hours: int = Query(default=24, ge=1, le=MAX_WINDOW_HOURS),
    db: Session = Depends(get_db),
):
    csv_text = _build_report_csv(db, hours)
    filename = f"mf_dashboard_report_{_now_beijing().strftime('%Y%m%d_%H%M%S')}.csv"
    return Response(
        content=csv_text,
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
