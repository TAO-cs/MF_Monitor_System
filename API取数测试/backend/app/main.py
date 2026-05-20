from __future__ import annotations

import hashlib
import hmac
import logging
import time
import uuid
from collections import deque
from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import Lock
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from sqlalchemy import and_, or_
from sqlalchemy.orm import Session

from .alarm_engine import ensure_default_rules
from .audit_service import orm_to_dict, record_audit_event
from .config import Settings
from .auth_api import router as auth_router
from .device_api import router as device_router
from .visualization_api import router as visualization_router
from .device_center import ensure_device_registry_defaults
from .db import Base, SessionLocal, engine, get_db
from .models import (
    Alarm,
    AlarmNotification,
    AlarmRule,
    AuditLog,
    Device,
    DeviceCommand,
    DeviceGroup,
    DeviceGroupMember,
    DeviceLocation,
    DeviceStatus,
    DisasterData,
    NotificationChannel,
    SpeedData,
)
from .mqtt_service import create_mqtt_client, publish_management_message
from .notification_service import NotificationWorker, ensure_default_notification_channels
from .security import ensure_default_platform_users, require_auth, require_roles
from .observability import (
    HTTP_4XX_TOTAL,
    HTTP_5XX_TOTAL,
    HTTP_REQUEST_DURATION_SECONDS,
    HTTP_REQUESTS_TOTAL,
    configure_json_logging,
    get_request_id,
    render_metrics,
    reset_request_id,
    set_request_id,
)
from .schemas import (
    AlarmRuleCreate,
    AlarmRuleEnabledUpdate,
    AlarmRuleUpdate,
    DeviceConfigPushRequest,
    DeviceCreate,
    DeviceEnabledUpdate,
    DeviceGroupCreate,
    DeviceGroupUpdate,
    DevicePermissionUpdate,
    DeviceUpdate,
    NotificationChannelCreate,
    NotificationChannelEnabledUpdate,
    NotificationChannelUpdate,
)

settings = Settings()
configure_json_logging(settings.log_level)

app = FastAPI(title="MF Monitor Platform", version="1.0.0")
app.include_router(auth_router)
app.include_router(device_router)
app.include_router(visualization_router)

EVIDENCE_ROOT = Path(settings.evidence_upload_dir).resolve()
EVIDENCE_ROOT.mkdir(parents=True, exist_ok=True)
app.mount("/evidence", StaticFiles(directory=str(EVIDENCE_ROOT)), name="evidence")

BEIJING_TZ = timezone(timedelta(hours=8))
auth_logger = logging.getLogger("mf.auth")
request_logger = logging.getLogger("mf.request")
app_logger = logging.getLogger("mf.app")

ALARM_EVENT_TYPES = {"classification", "speed", "device_status"}
ALARM_SEVERITIES = {"low", "medium", "high", "critical"}
DISASTER_TYPES = {"flood", "mudslide"}
ONLINE_STATUS = {"on", "off"}
CHANNEL_TYPES = {"webhook"}
AUDIT_OUTCOME_SUCCESS = "success"
AUDIT_OUTCOME_FAIL = "fail"

LIST_DEFAULT_PAGE_SIZE = 50
LIST_MAX_PAGE_SIZE = 200
LIST_DEFAULT_LIMIT = 200

MUTATING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}

_rate_limit_lock = Lock()
_rate_limit_buckets: dict[str, deque[float]] = {}

_idempotency_lock = Lock()
_idempotency_store: dict[str, dict[str, Any]] = {}


class ApiError(Exception):
    def __init__(self, status_code: int, code: str, message: str, detail: Any | None = None):
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.detail = detail


def _now_beijing() -> datetime:
    return datetime.now(BEIJING_TZ)


def _now_beijing_naive() -> datetime:
    return _now_beijing().replace(tzinfo=None)


def _to_beijing_naive(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value
    return value.astimezone(BEIJING_TZ).replace(tzinfo=None)


def _validate_time_range(start_time: datetime | None, end_time: datetime | None):
    if start_time and end_time and start_time > end_time:
        _raise_api_error(400, "INVALID_TIME_RANGE", "start_time must be <= end_time")


def _fingerprint(token: str) -> str:
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    return digest[:12]


def _sanitize_path_segment(raw: str, fallback: str) -> str:
    text = (raw or "").strip()
    if not text:
        return fallback
    cleaned = "".join(ch if ch.isalnum() or ch in {"-", "_", "."} else "_" for ch in text)
    cleaned = cleaned.strip("._")
    return cleaned or fallback


def _sanitize_filename(raw: str | None) -> str:
    original = Path((raw or "").strip() or "snapshot.jpg").name
    stem = _sanitize_path_segment(Path(original).stem, "snapshot")
    suffix = Path(original).suffix.lower()
    if suffix not in {".jpg", ".jpeg", ".png", ".webp"}:
        suffix = ".jpg"
    return f"{stem}{suffix}"


def _normalize_rule_condition(event_type: str, condition_json: dict) -> dict:
    event_type = (event_type or "").strip()
    if event_type not in ALARM_EVENT_TYPES:
        raise HTTPException(status_code=400, detail=f"unsupported event_type: {event_type}")

    cond = dict(condition_json or {})

    if event_type in {"classification", "speed"}:
        d_type = cond.get("disaster_type")
        if d_type is not None and d_type not in DISASTER_TYPES:
            raise HTTPException(status_code=400, detail="condition_json.disaster_type must be flood or mudslide")

    if event_type == "classification":
        if "min_confidence" in cond:
            try:
                min_conf = float(cond["min_confidence"])
            except (TypeError, ValueError):
                raise HTTPException(status_code=400, detail="condition_json.min_confidence must be a number")
            if min_conf < 0 or min_conf > 1:
                raise HTTPException(status_code=400, detail="condition_json.min_confidence must be between 0 and 1")
            cond["min_confidence"] = min_conf

    if event_type == "speed":
        if "min_avg_speed" in cond:
            try:
                min_avg = float(cond["min_avg_speed"])
            except (TypeError, ValueError):
                raise HTTPException(status_code=400, detail="condition_json.min_avg_speed must be a number")
            if min_avg < 0:
                raise HTTPException(status_code=400, detail="condition_json.min_avg_speed must be >= 0")
            cond["min_avg_speed"] = min_avg

        if "min_max_speed" in cond:
            try:
                min_max = float(cond["min_max_speed"])
            except (TypeError, ValueError):
                raise HTTPException(status_code=400, detail="condition_json.min_max_speed must be a number")
            if min_max < 0:
                raise HTTPException(status_code=400, detail="condition_json.min_max_speed must be >= 0")
            cond["min_max_speed"] = min_max

    if event_type == "device_status":
        if "online_status" in cond and cond["online_status"] not in ONLINE_STATUS:
            raise HTTPException(status_code=400, detail="condition_json.online_status must be on or off")

    return cond


def _normalize_channel_config(channel_type: str, config_json: dict) -> dict:
    channel_type = (channel_type or "").strip()
    if channel_type not in CHANNEL_TYPES:
        raise HTTPException(status_code=400, detail=f"unsupported channel_type: {channel_type}")

    config = dict(config_json or {})

    if channel_type == "webhook":
        raw_url = str(config.get("url", "")).strip()
        if not raw_url:
            raise HTTPException(status_code=400, detail="config_json.url is required for webhook")
        if not (raw_url.startswith("http://") or raw_url.startswith("https://")):
            raise HTTPException(status_code=400, detail="config_json.url must start with http:// or https://")

        headers = config.get("headers", {})
        if headers is None:
            headers = {}
        if not isinstance(headers, dict):
            raise HTTPException(status_code=400, detail="config_json.headers must be an object")

        normalized_headers = {str(k): str(v) for k, v in headers.items()}
        return {
            "url": raw_url,
            "headers": normalized_headers,
        }

    return config


def _get_rule_or_404(db: Session, rule_id: int) -> AlarmRule:
    item = db.query(AlarmRule).filter(AlarmRule.id == rule_id).first()
    if item is None:
        raise HTTPException(status_code=404, detail="alarm rule not found")
    return item


def _get_channel_or_404(db: Session, channel_id: int) -> NotificationChannel:
    item = db.query(NotificationChannel).filter(NotificationChannel.id == channel_id).first()
    if item is None:
        raise HTTPException(status_code=404, detail="notification channel not found")
    return item



def _get_device_or_404(db: Session, device_id: int) -> Device:
    item = db.query(Device).filter(Device.id == device_id).first()
    if item is None:
        raise HTTPException(status_code=404, detail="device not found")
    return item



def _get_group_or_404(db: Session, group_id: int) -> DeviceGroup:
    item = db.query(DeviceGroup).filter(DeviceGroup.id == group_id).first()
    if item is None:
        raise HTTPException(status_code=404, detail="device group not found")
    return item



def _upsert_device_location(
    db: Session,
    *,
    aibox_id: str,
    cam_id: str,
    location: str | None,
    latitude: float | None,
    longitude: float | None,
) -> DeviceLocation | None:
    if location is None and latitude is None and longitude is None:
        return None

    item = (
        db.query(DeviceLocation)
        .filter(DeviceLocation.aibox_id == aibox_id, DeviceLocation.cam_id == cam_id)
        .first()
    )
    if item is None:
        item = DeviceLocation(aibox_id=aibox_id, cam_id=cam_id)
        db.add(item)

    item.location = location
    item.latitude = latitude
    item.longitude = longitude
    db.flush()
    return item



def _serialize_device_overview(db: Session, devices: list[Device]) -> list[dict[str, Any]]:
    if not devices:
        return []

    device_ids = [item.id for item in devices]
    aibox_ids = sorted({item.aibox_id for item in devices})
    cam_ids = sorted({item.cam_id for item in devices})

    locations = {
        (row.aibox_id, row.cam_id): row
        for row in db.query(DeviceLocation)
        .filter(DeviceLocation.aibox_id.in_(aibox_ids), DeviceLocation.cam_id.in_(cam_ids))
        .all()
    }
    statuses = {
        (row.aibox_id, row.cam_id): row
        for row in db.query(DeviceStatus)
        .filter(DeviceStatus.aibox_id.in_(aibox_ids), DeviceStatus.cam_id.in_(cam_ids))
        .all()
    }

    groups_map: dict[int, list[dict[str, Any]]] = {device_id: [] for device_id in device_ids}
    group_rows = (
        db.query(DeviceGroupMember.device_id, DeviceGroup.group_code, DeviceGroup.group_name)
        .join(DeviceGroup, DeviceGroup.id == DeviceGroupMember.group_id)
        .filter(DeviceGroupMember.device_id.in_(device_ids))
        .order_by(DeviceGroup.group_code.asc())
        .all()
    )
    for row in group_rows:
        groups_map.setdefault(row.device_id, []).append(
            {
                "group_code": row.group_code,
                "group_name": row.group_name,
            }
        )

    items: list[dict[str, Any]] = []
    for device in devices:
        key = (device.aibox_id, device.cam_id)
        location = locations.get(key)
        status = statuses.get(key)
        items.append(
            {
                "id": device.id,
                "aibox_id": device.aibox_id,
                "cam_id": device.cam_id,
                "device_name": device.device_name,
                "device_type": device.device_type,
                "enabled": device.enabled,
                "allow_config_push": device.allow_config_push,
                "allow_remote_control": device.allow_remote_control,
                "metadata_json": device.metadata_json or {},
                "created_at": device.created_at,
                "updated_at": device.updated_at,
                "location": orm_to_dict(location) if location else None,
                "status": orm_to_dict(status) if status else None,
                "groups": groups_map.get(device.id, []),
            }
        )

    return items

def _audit_from_request(
    request: Request,
    *,
    action: str,
    outcome: str,
    status_code: int,
    entity_type: str | None = None,
    entity_id: str | int | None = None,
    detail: dict | None = None,
    before: dict | None = None,
    after: dict | None = None,
) -> None:
    actor_type = getattr(request.state, "actor_type", "anonymous")
    actor_id = getattr(request.state, "actor_id", "-")
    request_id = get_request_id()
    ip = request.client.host if request.client else "-"

    record_audit_event(
        request_id=request_id,
        actor_type=actor_type,
        actor_id=actor_id,
        action=action,
        outcome=outcome,
        path=request.url.path,
        method=request.method,
        status_code=status_code,
        client_ip=ip,
        entity_type=entity_type,
        entity_id=entity_id,
        detail=detail,
        before=before,
        after=after,
    )


def _audit_api_access(request: Request, status: int) -> None:
    if not request.url.path.startswith("/api/"):
        return

    outcome = AUDIT_OUTCOME_SUCCESS if 200 <= status < 400 else AUDIT_OUTCOME_FAIL
    _audit_from_request(
        request,
        action="api_access",
        outcome=outcome,
        status_code=status,
        detail={"query": request.url.query},
    )


def _default_error_code(status_code: int) -> str:
    mapping = {
        400: "BAD_REQUEST",
        401: "UNAUTHORIZED",
        403: "FORBIDDEN",
        404: "NOT_FOUND",
        409: "CONFLICT",
        422: "VALIDATION_ERROR",
        429: "RATE_LIMIT_EXCEEDED",
        500: "INTERNAL_ERROR",
    }
    return mapping.get(status_code, f"HTTP_{status_code}")


def _error_response(
    status_code: int,
    code: str,
    message: str,
    detail: Any | None = None,
    errors: list[dict[str, Any]] | None = None,
) -> JSONResponse:
    payload: dict[str, Any] = {
        "code": code,
        "message": message,
        "detail": message if detail is None else detail,
        "request_id": get_request_id(),
    }
    if errors is not None:
        payload["errors"] = errors
    return JSONResponse(status_code=status_code, content=payload)


def _raise_api_error(status_code: int, code: str, message: str, detail: Any | None = None) -> None:
    raise ApiError(status_code=status_code, code=code, message=message, detail=detail)


def _normalize_page_and_size(page: int, page_size: int) -> tuple[int, int]:
    if page < 1:
        _raise_api_error(400, "INVALID_PAGE", "page must be >= 1")
    if page_size < 1:
        _raise_api_error(400, "INVALID_PAGE_SIZE", "page_size must be >= 1")
    if page_size > LIST_MAX_PAGE_SIZE:
        _raise_api_error(
            400,
            "INVALID_PAGE_SIZE",
            f"page_size must be <= {LIST_MAX_PAGE_SIZE}",
        )
    return page, page_size


def _paginate_query(query, *, paginate: bool, page: int, page_size: int, order_by, default_limit: int = LIST_DEFAULT_LIMIT):
    ordered = query.order_by(order_by)
    if paginate:
        page, page_size = _normalize_page_and_size(page, page_size)
        total = query.order_by(None).count()
        items = ordered.offset((page - 1) * page_size).limit(page_size).all()
        return {
            "items": items,
            "total": total,
            "page": page,
            "page_size": page_size,
        }

    if default_limit and default_limit > 0:
        return ordered.limit(default_limit).all()
    return ordered.all()


def _extract_rate_limit_subject(request: Request) -> str:
    authorization = (request.headers.get("Authorization") or "").strip()
    if authorization.startswith("Bearer "):
        token = authorization[len("Bearer ") :].strip()
        if token:
            return f"api_key:{_fingerprint(token)}"

    ip = request.client.host if request.client else "-"
    return f"ip:{ip}"


def _check_rate_limit_or_raise(request: Request) -> None:
    if not settings.rate_limit_enabled:
        return
    if not request.url.path.startswith("/api/"):
        return

    window = max(1, int(settings.rate_limit_window_seconds))
    limit = max(1, int(settings.rate_limit_max_requests))

    subject = _extract_rate_limit_subject(request)
    bucket_key = f"{subject}:{request.method.upper()}:{request.url.path}"
    now_ts = time.time()

    with _rate_limit_lock:
        bucket = _rate_limit_buckets.get(bucket_key)
        if bucket is None:
            bucket = deque()
            _rate_limit_buckets[bucket_key] = bucket

        while bucket and now_ts - bucket[0] >= window:
            bucket.popleft()

        if len(bucket) >= limit:
            retry_after = int(max(1, window - (now_ts - bucket[0])))
            _raise_api_error(
                429,
                "RATE_LIMIT_EXCEEDED",
                "Too many requests",
                detail={
                    "retry_after_seconds": retry_after,
                    "limit": limit,
                    "window_seconds": window,
                },
            )

        bucket.append(now_ts)


def _cleanup_idempotency_store(now_ts: float) -> None:
    ttl = max(1, int(settings.idempotency_ttl_seconds))
    expire_before = now_ts - ttl

    stale_keys = [k for k, v in _idempotency_store.items() if float(v.get("created_at", 0)) < expire_before]
    for k in stale_keys:
        _idempotency_store.pop(k, None)

    max_entries = max(1, int(settings.idempotency_max_entries))
    overflow = len(_idempotency_store) - max_entries
    if overflow > 0:
        oldest = sorted(_idempotency_store.items(), key=lambda kv: float(kv[1].get("created_at", 0)))[:overflow]
        for k, _ in oldest:
            _idempotency_store.pop(k, None)


def _clone_request_with_body(request: Request, body: bytes) -> Request:
    async def receive() -> dict[str, Any]:
        return {"type": "http.request", "body": body, "more_body": False}

    return Request(request.scope, receive)


@app.middleware("http")
async def request_middleware(request: Request, call_next):
    request_id = request.headers.get("X-Request-Id") or str(uuid.uuid4())
    token = set_request_id(request_id)
    start = time.perf_counter()

    if not hasattr(request.state, "actor_type"):
        request.state.actor_type = "anonymous"
    if not hasattr(request.state, "actor_id"):
        request.state.actor_id = "-"

    try:
        response: Response | None = None
        idempotency_meta: dict[str, Any] | None = None
        downstream_request = request

        try:
            _check_rate_limit_or_raise(request)

            idempotency_key = (request.headers.get("Idempotency-Key") or "").strip()
            is_idempotency_target = (
                settings.idempotency_enabled
                and request.url.path.startswith("/api/")
                and request.method.upper() in MUTATING_METHODS
                and bool(idempotency_key)
            )

            if is_idempotency_target:
                raw_body = await request.body()
                body_hash = hashlib.sha256(raw_body).hexdigest()
                compound_key = f"{request.method.upper()}:{request.url.path}:{idempotency_key}"
                now_ts = time.time()

                with _idempotency_lock:
                    _cleanup_idempotency_store(now_ts)
                    existing = _idempotency_store.get(compound_key)

                    if existing is not None:
                        if str(existing.get("body_hash")) != body_hash:
                            _raise_api_error(
                                409,
                                "IDEMPOTENCY_KEY_REUSE_CONFLICT",
                                "Idempotency-Key was reused with different payload",
                            )

                        replay_headers = {
                            k: v
                            for k, v in dict(existing.get("headers") or {}).items()
                            if k.lower() != "content-length"
                        }
                        replay_headers["X-Idempotent-Replay"] = "1"
                        response = Response(
                            content=bytes(existing.get("body") or b""),
                            status_code=int(existing.get("status_code") or 200),
                            headers=replay_headers,
                            media_type=existing.get("media_type") or "application/json",
                        )
                    else:
                        idempotency_meta = {
                            "compound_key": compound_key,
                            "body_hash": body_hash,
                        }

                downstream_request = _clone_request_with_body(request, raw_body)

            if response is None:
                response = await call_next(downstream_request)

                if idempotency_meta is not None and response.status_code < 500:
                    collected = b""
                    if getattr(response, "body_iterator", None) is not None:
                        async for chunk in response.body_iterator:
                            collected += chunk
                    elif hasattr(response, "body") and response.body is not None:
                        collected = bytes(response.body)

                    rebuilt_headers = {
                        k: v for k, v in response.headers.items() if k.lower() != "content-length"
                    }
                    rebuilt = Response(
                        content=collected,
                        status_code=response.status_code,
                        headers=rebuilt_headers,
                        media_type=response.media_type,
                    )

                    max_body = max(1024, int(settings.idempotency_max_body_bytes))
                    if len(collected) <= max_body:
                        now_ts = time.time()
                        with _idempotency_lock:
                            _cleanup_idempotency_store(now_ts)
                            _idempotency_store[idempotency_meta["compound_key"]] = {
                                "created_at": now_ts,
                                "body_hash": idempotency_meta["body_hash"],
                                "status_code": rebuilt.status_code,
                                "media_type": rebuilt.media_type,
                                "body": collected,
                                "headers": {
                                    k: v
                                    for k, v in rebuilt.headers.items()
                                    if k.lower() not in {"content-length", "x-request-id"}
                                },
                            }

                    response = rebuilt

        except ApiError as api_exc:
            response = _error_response(
                api_exc.status_code,
                api_exc.code,
                api_exc.message,
                detail=api_exc.detail,
            )

        except Exception:
            duration = time.perf_counter() - start
            path = request.url.path
            method = request.method

            HTTP_REQUESTS_TOTAL.labels(method=method, path=path, status="500").inc()
            HTTP_5XX_TOTAL.labels(path=path).inc()
            HTTP_REQUEST_DURATION_SECONDS.labels(method=method, path=path).observe(duration)

            request_logger.exception(
                "request_failed",
                extra={
                    "path": path,
                    "method": method,
                    "status": 500,
                    "duration_ms": round(duration * 1000, 2),
                    "ip": request.client.host if request.client else "-",
                },
            )
            _audit_api_access(request, 500)
            raise

        status = response.status_code
        duration = time.perf_counter() - start
        path = request.url.path
        method = request.method

        HTTP_REQUESTS_TOTAL.labels(method=method, path=path, status=str(status)).inc()
        HTTP_REQUEST_DURATION_SECONDS.labels(method=method, path=path).observe(duration)
        if 400 <= status < 500:
            HTTP_4XX_TOTAL.labels(path=path).inc()
        elif status >= 500:
            HTTP_5XX_TOTAL.labels(path=path).inc()

        response.headers["X-Request-Id"] = request_id
        response.headers["X-Backend-Instance"] = settings.app_instance_id
        response.headers["X-Release-Version"] = settings.app_release_version
        response.headers["X-Release-Channel"] = settings.app_release_channel
        request_logger.info(
            "request_done",
            extra={
                "path": path,
                "method": method,
                "status": status,
                "duration_ms": round(duration * 1000, 2),
                "ip": request.client.host if request.client else "-",
            },
        )
        _audit_api_access(request, status)
        return response
    finally:
        reset_request_id(token)


@app.exception_handler(ApiError)
async def api_error_exception_handler(request: Request, exc: ApiError):
    return _error_response(exc.status_code, exc.code, exc.message, detail=exc.detail)


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    status_code = exc.status_code
    detail = exc.detail

    if isinstance(detail, dict) and "code" in detail and "message" in detail:
        return _error_response(
            status_code,
            str(detail.get("code")),
            str(detail.get("message")),
            detail=detail.get("detail"),
            errors=detail.get("errors"),
        )

    message = detail if isinstance(detail, str) else "HTTP error"
    return _error_response(status_code, _default_error_code(status_code), message, detail=detail)


@app.exception_handler(RequestValidationError)
async def request_validation_exception_handler(request: Request, exc: RequestValidationError):
    return _error_response(
        422,
        "VALIDATION_ERROR",
        "Request validation failed",
        detail="Request validation failed",
        errors=exc.errors(),
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    request_logger.exception("unhandled_exception", extra={"path": request.url.path, "method": request.method})
    return _error_response(500, "INTERNAL_ERROR", "Internal server error")


def require_api_key(
    request: Request,
    authorization: str | None = Header(default=None),
    db: Session = Depends(get_db),
):
    return require_auth(request=request, db=db, authorization=authorization)


@app.post("/api/evidence/upload", dependencies=[Depends(require_api_key)])
async def api_evidence_upload(
    request: Request,
    aibox_id: str = Query(..., min_length=1, max_length=50),
    cam_id: str = Query(..., min_length=1, max_length=50),
    filename: str | None = Header(default=None, alias="X-File-Name"),
):
    payload = await request.body()
    if not payload:
        raise HTTPException(status_code=400, detail="empty upload body")

    safe_aibox_id = _sanitize_path_segment(aibox_id, "unknown_aibox")
    safe_cam_id = _sanitize_path_segment(cam_id, "unknown_cam")
    safe_name = _sanitize_filename(filename)

    target_dir = EVIDENCE_ROOT / safe_aibox_id / safe_cam_id
    target_dir.mkdir(parents=True, exist_ok=True)

    timestamp = _now_beijing().strftime("%Y%m%d_%H%M%S")
    save_name = f"{timestamp}_{safe_name}"
    target_path = target_dir / save_name
    target_path.write_bytes(payload)

    relative_path = f"/evidence/{safe_aibox_id}/{safe_cam_id}/{save_name}"
    return {
        "aibox_id": aibox_id,
        "cam_id": cam_id,
        "image_path": relative_path,
        "image_url": relative_path,
        "content_type": request.headers.get("content-type") or "application/octet-stream",
        "size_bytes": len(payload),
        "saved_name": save_name,
    }

Base.metadata.create_all(bind=engine)
with SessionLocal() as _bootstrap_db:
    ensure_device_registry_defaults(_bootstrap_db)
    ensure_default_rules(_bootstrap_db)
    ensure_default_notification_channels(_bootstrap_db)
    ensure_default_platform_users(_bootstrap_db)

mqtt_client = create_mqtt_client()
notify_worker = NotificationWorker(settings.notify_worker_interval_seconds)


@app.on_event("startup")
def startup_event():
    if settings.enable_ingestion:
        notify_worker.start()
        mqtt_client.connect(settings.mqtt_broker_host, settings.mqtt_broker_port, keepalive=60)
        mqtt_client.loop_start()
        app_logger.info(
            "ingestion_started",
            extra={
                "instance_id": settings.app_instance_id,
                "mqtt_host": settings.mqtt_broker_host,
                "mqtt_port": settings.mqtt_broker_port,
            },
        )
    else:
        app_logger.info(
            "ingestion_disabled",
            extra={
                "instance_id": settings.app_instance_id,
            },
        )


@app.on_event("shutdown")
def shutdown_event():
    if settings.enable_ingestion:
        mqtt_client.loop_stop()
        mqtt_client.disconnect()
        notify_worker.stop()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "time": _now_beijing().isoformat(),
        "timezone": "Asia/Shanghai",
        "env": settings.app_env,
        "instance_id": settings.app_instance_id,
        "release_version": settings.app_release_version,
        "release_channel": settings.app_release_channel,
        "ingestion_enabled": settings.enable_ingestion,
    }


@app.get("/metrics")
def metrics():
    body, content_type = render_metrics()
    return Response(content=body, media_type=content_type)


@app.get("/api/device_location", dependencies=[Depends(require_auth)])
def api_device_location(
    aibox_id: str | None = Query(default=None, min_length=1, max_length=50),
    cam_id: str | None = Query(default=None, min_length=1, max_length=50),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    q = db.query(DeviceLocation)
    if aibox_id:
        q = q.filter(DeviceLocation.aibox_id == aibox_id)
    if cam_id:
        q = q.filter(DeviceLocation.cam_id == cam_id)
    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=DeviceLocation.id.desc(),
        default_limit=500,
    )


@app.get("/api/device_status", dependencies=[Depends(require_auth)])
def api_device_status(
    aibox_id: str | None = Query(default=None, min_length=1, max_length=50),
    cam_id: str | None = Query(default=None, min_length=1, max_length=50),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    q = db.query(DeviceStatus)
    if aibox_id:
        q = q.filter(DeviceStatus.aibox_id == aibox_id)
    if cam_id:
        q = q.filter(DeviceStatus.cam_id == cam_id)
    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=DeviceStatus.id.desc(),
        default_limit=500,
    )


@app.get("/api/classification", dependencies=[Depends(require_auth)])
def api_classification(
    aibox_id: str | None = Query(default=None, min_length=1, max_length=50),
    cam_id: str | None = Query(default=None, min_length=1, max_length=50),
    start_time: datetime | None = None,
    end_time: datetime | None = None,
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    start_time = _to_beijing_naive(start_time)
    end_time = _to_beijing_naive(end_time)
    _validate_time_range(start_time, end_time)

    q = db.query(DisasterData)
    if aibox_id:
        q = q.filter(DisasterData.aibox_id == aibox_id)
    if cam_id:
        q = q.filter(DisasterData.cam_id == cam_id)
    if start_time:
        q = q.filter(DisasterData.timestamp >= start_time)
    if end_time:
        q = q.filter(DisasterData.timestamp <= end_time)
    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=DisasterData.id.desc(),
        default_limit=200,
    )


@app.get("/api/speed", dependencies=[Depends(require_auth)])
def api_speed(
    aibox_id: str | None = Query(default=None, min_length=1, max_length=50),
    cam_id: str | None = Query(default=None, min_length=1, max_length=50),
    start_time: datetime | None = None,
    end_time: datetime | None = None,
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    start_time = _to_beijing_naive(start_time)
    end_time = _to_beijing_naive(end_time)
    _validate_time_range(start_time, end_time)

    q = db.query(SpeedData)
    if aibox_id:
        q = q.filter(SpeedData.aibox_id == aibox_id)
    if cam_id:
        q = q.filter(SpeedData.cam_id == cam_id)
    if start_time:
        q = q.filter(SpeedData.timestamp >= start_time)
    if end_time:
        q = q.filter(SpeedData.timestamp <= end_time)
    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=SpeedData.id.desc(),
        default_limit=200,
    )


@app.get("/api/alarm_rules", dependencies=[Depends(require_auth)])
def api_alarm_rules(
    event_type: str | None = Query(default=None),
    enabled: bool | None = Query(default=None),
    rule_code: str | None = Query(default=None, min_length=1, max_length=64),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    q = db.query(AlarmRule)
    if event_type:
        q = q.filter(AlarmRule.event_type == event_type)
    if enabled is not None:
        q = q.filter(AlarmRule.enabled == enabled)
    if rule_code:
        q = q.filter(AlarmRule.rule_code == rule_code)
    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=AlarmRule.id.asc(),
        default_limit=500,
    )


@app.post("/api/alarm_rules", dependencies=[Depends(require_roles("admin"))])
def api_alarm_rule_create(payload: AlarmRuleCreate, request: Request, db: Session = Depends(get_db)):
    exists = db.query(AlarmRule.id).filter(AlarmRule.rule_code == payload.rule_code).first()
    if exists is not None:
        _audit_from_request(
            request,
            action="alarm_rule_create",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=409,
            entity_type="alarm_rule",
            entity_id=payload.rule_code,
            detail={"reason": "rule_code_exists"},
        )
        raise HTTPException(status_code=409, detail="rule_code already exists")

    normalized_cond = _normalize_rule_condition(payload.event_type, payload.condition_json)

    item = AlarmRule(
        rule_code=payload.rule_code,
        name=payload.name,
        event_type=payload.event_type,
        severity=payload.severity,
        enabled=payload.enabled,
        cooldown_seconds=payload.cooldown_seconds,
        condition_json=normalized_cond,
    )
    db.add(item)
    db.commit()
    db.refresh(item)

    _audit_from_request(
        request,
        action="alarm_rule_create",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="alarm_rule",
        entity_id=item.id,
        after=orm_to_dict(item),
    )

    return item


@app.put("/api/alarm_rules/{rule_id}", dependencies=[Depends(require_roles("admin"))])
def api_alarm_rule_update(rule_id: int, payload: AlarmRuleUpdate, request: Request, db: Session = Depends(get_db)):
    item = _get_rule_or_404(db, rule_id)

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        _audit_from_request(
            request,
            action="alarm_rule_update",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=400,
            entity_type="alarm_rule",
            entity_id=rule_id,
            detail={"reason": "no_fields_to_update"},
        )
        raise HTTPException(status_code=400, detail="no fields to update")

    before = orm_to_dict(item)

    event_type = updates.get("event_type", item.event_type)
    condition_json = updates.get("condition_json", item.condition_json)
    normalized_cond = _normalize_rule_condition(event_type, condition_json)

    if "name" in updates:
        item.name = updates["name"]
    if "event_type" in updates:
        item.event_type = updates["event_type"]
    if "severity" in updates:
        if updates["severity"] not in ALARM_SEVERITIES:
            _audit_from_request(
                request,
                action="alarm_rule_update",
                outcome=AUDIT_OUTCOME_FAIL,
                status_code=400,
                entity_type="alarm_rule",
                entity_id=rule_id,
                detail={"reason": "invalid_severity"},
                before=before,
            )
            raise HTTPException(status_code=400, detail="invalid severity")
        item.severity = updates["severity"]
    if "enabled" in updates:
        item.enabled = updates["enabled"]
    if "cooldown_seconds" in updates:
        item.cooldown_seconds = updates["cooldown_seconds"]

    item.condition_json = normalized_cond

    db.commit()
    db.refresh(item)

    _audit_from_request(
        request,
        action="alarm_rule_update",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="alarm_rule",
        entity_id=item.id,
        before=before,
        after=orm_to_dict(item),
    )

    return item


@app.patch("/api/alarm_rules/{rule_id}/enabled", dependencies=[Depends(require_roles("admin"))])
def api_alarm_rule_enabled(rule_id: int, payload: AlarmRuleEnabledUpdate, request: Request, db: Session = Depends(get_db)):
    item = _get_rule_or_404(db, rule_id)
    before = orm_to_dict(item)

    item.enabled = payload.enabled
    db.commit()
    db.refresh(item)

    _audit_from_request(
        request,
        action="alarm_rule_enabled",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="alarm_rule",
        entity_id=item.id,
        before=before,
        after=orm_to_dict(item),
    )

    return item


@app.get("/api/notification_channels", dependencies=[Depends(require_auth)])
def api_notification_channels(
    enabled: bool | None = Query(default=None),
    channel_type: str | None = Query(default=None),
    channel_code: str | None = Query(default=None, min_length=1, max_length=64),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    q = db.query(NotificationChannel)
    if enabled is not None:
        q = q.filter(NotificationChannel.enabled == enabled)
    if channel_type:
        q = q.filter(NotificationChannel.channel_type == channel_type)
    if channel_code:
        q = q.filter(NotificationChannel.channel_code == channel_code)
    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=NotificationChannel.id.asc(),
        default_limit=500,
    )


@app.post("/api/notification_channels", dependencies=[Depends(require_roles("admin"))])
def api_notification_channel_create(payload: NotificationChannelCreate, request: Request, db: Session = Depends(get_db)):
    exists = db.query(NotificationChannel.id).filter(NotificationChannel.channel_code == payload.channel_code).first()
    if exists is not None:
        _audit_from_request(
            request,
            action="notification_channel_create",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=409,
            entity_type="notification_channel",
            entity_id=payload.channel_code,
            detail={"reason": "channel_code_exists"},
        )
        raise HTTPException(status_code=409, detail="channel_code already exists")

    normalized_cfg = _normalize_channel_config(payload.channel_type, payload.config_json)

    item = NotificationChannel(
        channel_code=payload.channel_code,
        name=payload.name,
        channel_type=payload.channel_type,
        enabled=payload.enabled,
        retry_max=payload.retry_max,
        retry_interval_seconds=payload.retry_interval_seconds,
        timeout_seconds=payload.timeout_seconds,
        config_json=normalized_cfg,
    )
    db.add(item)
    db.commit()
    db.refresh(item)

    _audit_from_request(
        request,
        action="notification_channel_create",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="notification_channel",
        entity_id=item.id,
        after=orm_to_dict(item),
    )

    return item


@app.put("/api/notification_channels/{channel_id}", dependencies=[Depends(require_roles("admin"))])
def api_notification_channel_update(
    channel_id: int,
    payload: NotificationChannelUpdate,
    request: Request,
    db: Session = Depends(get_db),
):
    item = _get_channel_or_404(db, channel_id)

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        _audit_from_request(
            request,
            action="notification_channel_update",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=400,
            entity_type="notification_channel",
            entity_id=channel_id,
            detail={"reason": "no_fields_to_update"},
        )
        raise HTTPException(status_code=400, detail="no fields to update")

    before = orm_to_dict(item)

    channel_type = updates.get("channel_type", item.channel_type)
    config_json = updates.get("config_json", item.config_json)
    normalized_cfg = _normalize_channel_config(channel_type, config_json)

    if "name" in updates:
        item.name = updates["name"]
    if "channel_type" in updates:
        item.channel_type = updates["channel_type"]
    if "enabled" in updates:
        item.enabled = updates["enabled"]
    if "retry_max" in updates:
        item.retry_max = updates["retry_max"]
    if "retry_interval_seconds" in updates:
        item.retry_interval_seconds = updates["retry_interval_seconds"]
    if "timeout_seconds" in updates:
        item.timeout_seconds = updates["timeout_seconds"]

    item.config_json = normalized_cfg

    db.commit()
    db.refresh(item)

    _audit_from_request(
        request,
        action="notification_channel_update",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="notification_channel",
        entity_id=item.id,
        before=before,
        after=orm_to_dict(item),
    )

    return item


@app.patch("/api/notification_channels/{channel_id}/enabled", dependencies=[Depends(require_roles("admin"))])
def api_notification_channel_enabled(
    channel_id: int,
    payload: NotificationChannelEnabledUpdate,
    request: Request,
    db: Session = Depends(get_db),
):
    item = _get_channel_or_404(db, channel_id)
    before = orm_to_dict(item)

    item.enabled = payload.enabled
    db.commit()
    db.refresh(item)

    _audit_from_request(
        request,
        action="notification_channel_enabled",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="notification_channel",
        entity_id=item.id,
        before=before,
        after=orm_to_dict(item),
    )

    return item


@app.get("/api/alarm_notifications", dependencies=[Depends(require_auth)])
def api_alarm_notifications(
    alarm_id: int | None = Query(default=None),
    channel_code: str | None = Query(default=None, min_length=1, max_length=64),
    status: str | None = Query(default=None),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    q = db.query(AlarmNotification)
    if alarm_id is not None:
        q = q.filter(AlarmNotification.alarm_id == alarm_id)
    if channel_code:
        q = q.filter(AlarmNotification.channel_code == channel_code)
    if status:
        q = q.filter(AlarmNotification.status == status)
    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=AlarmNotification.id.desc(),
        default_limit=500,
    )


@app.post("/api/alarm_notifications/{notification_id}/retry", dependencies=[Depends(require_roles("operator", "admin"))])
def api_alarm_notification_retry(notification_id: int, request: Request, db: Session = Depends(get_db)):
    item = db.query(AlarmNotification).filter(AlarmNotification.id == notification_id).first()
    if item is None:
        _audit_from_request(
            request,
            action="alarm_notification_retry",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=404,
            entity_type="alarm_notification",
            entity_id=notification_id,
            detail={"reason": "not_found"},
        )
        raise HTTPException(status_code=404, detail="alarm notification not found")

    before = orm_to_dict(item)

    item.next_retry_at = _now_beijing_naive()
    if item.status != "sent":
        item.status = "pending"
    db.commit()
    db.refresh(item)

    _audit_from_request(
        request,
        action="alarm_notification_retry",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="alarm_notification",
        entity_id=item.id,
        before=before,
        after=orm_to_dict(item),
    )

    return {
        "ok": True,
        "id": item.id,
        "status": item.status,
        "next_retry_at": item.next_retry_at,
    }


@app.get("/api/audit_logs", dependencies=[Depends(require_roles("admin"))])
def api_audit_logs(
    action: str | None = Query(default=None, min_length=1, max_length=64),
    outcome: str | None = Query(default=None, min_length=1, max_length=16),
    actor_type: str | None = Query(default=None, min_length=1, max_length=32),
    entity_type: str | None = Query(default=None, min_length=1, max_length=64),
    entity_id: str | None = Query(default=None, min_length=1, max_length=64),
    path: str | None = Query(default=None, min_length=1, max_length=255),
    method: str | None = Query(default=None, min_length=1, max_length=16),
    request_id: str | None = Query(default=None, min_length=1, max_length=64),
    start_time: datetime | None = None,
    end_time: datetime | None = None,
    limit: int = Query(default=200, ge=1, le=1000),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    start_time = _to_beijing_naive(start_time)
    end_time = _to_beijing_naive(end_time)
    _validate_time_range(start_time, end_time)

    q = db.query(AuditLog)
    if action:
        q = q.filter(AuditLog.action == action)
    if outcome:
        q = q.filter(AuditLog.outcome == outcome)
    if actor_type:
        q = q.filter(AuditLog.actor_type == actor_type)
    if entity_type:
        q = q.filter(AuditLog.entity_type == entity_type)
    if entity_id:
        q = q.filter(AuditLog.entity_id == entity_id)
    if path:
        q = q.filter(AuditLog.path == path)
    if method:
        q = q.filter(AuditLog.method == method.upper())
    if request_id:
        q = q.filter(AuditLog.request_id == request_id)
    if start_time:
        q = q.filter(AuditLog.created_at >= start_time)
    if end_time:
        q = q.filter(AuditLog.created_at <= end_time)

    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=AuditLog.id.desc(),
        default_limit=limit,
    )


@app.get("/api/alarms", dependencies=[Depends(require_auth)])
def api_alarms(
    status: str | None = Query(default=None),
    severity: str | None = Query(default=None),
    event_type: str | None = Query(default=None),
    rule_code: str | None = Query(default=None, min_length=1, max_length=64),
    aibox_id: str | None = Query(default=None, min_length=1, max_length=50),
    cam_id: str | None = Query(default=None, min_length=1, max_length=50),
    start_time: datetime | None = None,
    end_time: datetime | None = None,
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    start_time = _to_beijing_naive(start_time)
    end_time = _to_beijing_naive(end_time)
    _validate_time_range(start_time, end_time)

    q = db.query(Alarm)
    if status:
        q = q.filter(Alarm.status == status)
    if severity:
        q = q.filter(Alarm.severity == severity)
    if event_type:
        q = q.filter(Alarm.event_type == event_type)
    if rule_code:
        q = q.filter(Alarm.rule_code == rule_code)
    if aibox_id:
        q = q.filter(Alarm.aibox_id == aibox_id)
    if cam_id:
        q = q.filter(Alarm.cam_id == cam_id)
    if start_time:
        q = q.filter(Alarm.triggered_at >= start_time)
    if end_time:
        q = q.filter(Alarm.triggered_at <= end_time)
    return _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=Alarm.id.desc(),
        default_limit=500,
    )


@app.post("/api/alarms/{alarm_id}/ack", dependencies=[Depends(require_roles("operator", "admin"))])
def api_alarm_ack(alarm_id: int, request: Request, db: Session = Depends(get_db)):
    item = db.query(Alarm).filter(Alarm.id == alarm_id).first()
    if item is None:
        _audit_from_request(
            request,
            action="alarm_ack",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=404,
            entity_type="alarm",
            entity_id=alarm_id,
            detail={"reason": "not_found"},
        )
        raise HTTPException(status_code=404, detail="alarm not found")

    before = orm_to_dict(item)

    if item.status != "closed":
        item.status = "ack"
        db.commit()
        db.refresh(item)

    _audit_from_request(
        request,
        action="alarm_ack",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="alarm",
        entity_id=item.id,
        before=before,
        after=orm_to_dict(item),
    )

    return {"ok": True, "id": item.id, "status": item.status}


@app.post("/api/alarms/{alarm_id}/close", dependencies=[Depends(require_roles("operator", "admin"))])
def api_alarm_close(alarm_id: int, request: Request, db: Session = Depends(get_db)):
    item = db.query(Alarm).filter(Alarm.id == alarm_id).first()
    if item is None:
        _audit_from_request(
            request,
            action="alarm_close",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=404,
            entity_type="alarm",
            entity_id=alarm_id,
            detail={"reason": "not_found"},
        )
        raise HTTPException(status_code=404, detail="alarm not found")

    before = orm_to_dict(item)

    if item.status != "closed":
        item.status = "closed"
        item.recovered_at = _now_beijing_naive()
        db.commit()
        db.refresh(item)

    _audit_from_request(
        request,
        action="alarm_close",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="alarm",
        entity_id=item.id,
        before=before,
        after=orm_to_dict(item),
    )

    return {"ok": True, "id": item.id, "status": item.status}

























