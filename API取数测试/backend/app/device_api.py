from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from sqlalchemy import and_, or_
from sqlalchemy.orm import Session

from .audit_service import orm_to_dict, record_audit_event
from .db import get_db
from .models import Device, DeviceCommand, DeviceGroup, DeviceGroupMember, DeviceLocation, DeviceStatus
from .mqtt_service import publish_management_message
from .security import require_auth, require_roles
from .observability import get_request_id
from .schemas import (
    DeviceConfigPushRequest,
    DeviceCreate,
    DeviceEnabledUpdate,
    DeviceGroupCreate,
    DeviceGroupUpdate,
    DevicePermissionUpdate,
    DeviceUpdate,
)

router = APIRouter(tags=["device-center"])

BEIJING_TZ = timezone(timedelta(hours=8))

LIST_DEFAULT_PAGE_SIZE = 50
LIST_MAX_PAGE_SIZE = 200
LIST_DEFAULT_LIMIT = 200
AUDIT_OUTCOME_SUCCESS = "success"
AUDIT_OUTCOME_FAIL = "fail"
ONLINE_STATUS = {"on", "off"}


def _now_beijing() -> datetime:
    return datetime.now(BEIJING_TZ)


def _now_beijing_naive() -> datetime:
    return _now_beijing().replace(tzinfo=None)


def _require_api_key(
    request: Request,
    db: Session = Depends(get_db),
    authorization: str | None = Header(default=None),
):
    return require_auth(request=request, db=db, authorization=authorization)

def _audit_from_request(
    request: Request,
    *,
    action: str,
    outcome: str,
    status_code: int,
    entity_type: str | None = None,
    entity_id: str | int | None = None,
    detail: dict[str, Any] | None = None,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
) -> None:
    record_audit_event(
        request_id=get_request_id(),
        actor_type=getattr(request.state, "actor_type", "anonymous"),
        actor_id=getattr(request.state, "actor_id", "-"),
        action=action,
        outcome=outcome,
        path=request.url.path,
        method=request.method,
        status_code=status_code,
        client_ip=request.client.host if request.client else "-",
        entity_type=entity_type,
        entity_id=entity_id,
        detail=detail,
        before=before,
        after=after,
    )


def _normalize_page_and_size(page: int, page_size: int) -> tuple[int, int]:
    if page < 1:
        raise HTTPException(status_code=400, detail="page must be >= 1")
    if page_size < 1:
        raise HTTPException(status_code=400, detail="page_size must be >= 1")
    if page_size > LIST_MAX_PAGE_SIZE:
        raise HTTPException(status_code=400, detail=f"page_size must be <= {LIST_MAX_PAGE_SIZE}")
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


def _serialize_group_list(db: Session, groups: list[DeviceGroup]) -> list[dict[str, Any]]:
    if not groups:
        return []

    group_ids = [item.id for item in groups]
    counts: dict[int, int] = {group_id: 0 for group_id in group_ids}
    rows = db.query(DeviceGroupMember.group_id).filter(DeviceGroupMember.group_id.in_(group_ids)).all()
    for row in rows:
        counts[row.group_id] = counts.get(row.group_id, 0) + 1

    items: list[dict[str, Any]] = []
    for group in groups:
        data = orm_to_dict(group) or {}
        data["device_count"] = counts.get(group.id, 0)
        items.append(data)
    return items


def _build_overview_summary(items: list[dict[str, Any]]) -> dict[str, int]:
    summary = {
        "matched_count": len(items),
        "online": 0,
        "offline": 0,
        "unknown": 0,
        "enabled": 0,
        "disabled": 0,
    }
    for item in items:
        if item.get("enabled"):
            summary["enabled"] += 1
        else:
            summary["disabled"] += 1

        status = item.get("status") or {}
        online_status = status.get("online_status")
        if online_status == "on":
            summary["online"] += 1
        elif online_status == "off":
            summary["offline"] += 1
        else:
            summary["unknown"] += 1
    return summary


@router.get("/api/devices", dependencies=[Depends(require_auth)])
def api_devices(
    aibox_id: str | None = Query(default=None, min_length=1, max_length=50),
    cam_id: str | None = Query(default=None, min_length=1, max_length=50),
    enabled: bool | None = Query(default=None),
    group_code: str | None = Query(default=None, min_length=1, max_length=64),
    keyword: str | None = Query(default=None, min_length=1, max_length=100),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    q = db.query(Device)
    if group_code:
        q = (
            q.join(DeviceGroupMember, DeviceGroupMember.device_id == Device.id)
            .join(DeviceGroup, DeviceGroup.id == DeviceGroupMember.group_id)
            .filter(DeviceGroup.group_code == group_code)
        )
    if aibox_id:
        q = q.filter(Device.aibox_id == aibox_id)
    if cam_id:
        q = q.filter(Device.cam_id == cam_id)
    if enabled is not None:
        q = q.filter(Device.enabled == enabled)
    if keyword:
        like = f"%{keyword}%"
        q = q.filter(
            or_(
                Device.aibox_id.like(like),
                Device.cam_id.like(like),
                Device.device_name.like(like),
                Device.device_type.like(like),
            )
        )
    q = q.distinct()

    result = _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=Device.id.asc(),
        default_limit=500,
    )
    if paginate:
        result["items"] = _serialize_device_overview(db, result["items"])
        return result
    return _serialize_device_overview(db, result)


@router.post("/api/devices", dependencies=[Depends(require_roles("admin"))])
def api_device_create(payload: DeviceCreate, request: Request, db: Session = Depends(get_db)):
    exists = (
        db.query(Device.id)
        .filter(Device.aibox_id == payload.aibox_id, Device.cam_id == payload.cam_id)
        .first()
    )
    if exists is not None:
        _audit_from_request(
            request,
            action="device_create",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=409,
            entity_type="device",
            entity_id=f"{payload.aibox_id}:{payload.cam_id}",
            detail={"reason": "device_exists"},
        )
        raise HTTPException(status_code=409, detail="device already exists")

    item = Device(
        aibox_id=payload.aibox_id,
        cam_id=payload.cam_id,
        device_name=payload.device_name,
        device_type=payload.device_type,
        enabled=payload.enabled,
        allow_config_push=payload.allow_config_push,
        allow_remote_control=payload.allow_remote_control,
        metadata_json=payload.metadata_json or {},
    )
    db.add(item)
    db.flush()

    _upsert_device_location(
        db,
        aibox_id=payload.aibox_id,
        cam_id=payload.cam_id,
        location=payload.location,
        latitude=payload.latitude,
        longitude=payload.longitude,
    )

    db.commit()
    db.refresh(item)
    after = _serialize_device_overview(db, [item])[0]

    _audit_from_request(
        request,
        action="device_create",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device",
        entity_id=item.id,
        after=after,
    )
    return after


@router.put("/api/devices/{device_id}", dependencies=[Depends(require_roles("admin"))])
def api_device_update(device_id: int, payload: DeviceUpdate, request: Request, db: Session = Depends(get_db)):
    item = _get_device_or_404(db, device_id)
    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        _audit_from_request(
            request,
            action="device_update",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=400,
            entity_type="device",
            entity_id=device_id,
            detail={"reason": "no_fields_to_update"},
        )
        raise HTTPException(status_code=400, detail="no fields to update")

    before = _serialize_device_overview(db, [item])[0]

    if "device_name" in updates:
        item.device_name = updates["device_name"]
    if "device_type" in updates:
        item.device_type = updates["device_type"]
    if "enabled" in updates:
        item.enabled = updates["enabled"]
    if "allow_config_push" in updates:
        item.allow_config_push = updates["allow_config_push"]
    if "allow_remote_control" in updates:
        item.allow_remote_control = updates["allow_remote_control"]
    if "metadata_json" in updates:
        item.metadata_json = updates["metadata_json"] or {}

    location_keys = {"location", "latitude", "longitude"}
    if location_keys & set(updates.keys()):
        if updates.get("location") is None or updates.get("latitude") is None or updates.get("longitude") is None:
            _audit_from_request(
                request,
                action="device_update",
                outcome=AUDIT_OUTCOME_FAIL,
                status_code=400,
                entity_type="device",
                entity_id=device_id,
                detail={"reason": "location_fields_cannot_be_null"},
                before=before,
            )
            raise HTTPException(status_code=400, detail="location fields cannot be null")

        _upsert_device_location(
            db,
            aibox_id=item.aibox_id,
            cam_id=item.cam_id,
            location=updates.get("location"),
            latitude=updates.get("latitude"),
            longitude=updates.get("longitude"),
        )

    db.commit()
    db.refresh(item)
    after = _serialize_device_overview(db, [item])[0]

    _audit_from_request(
        request,
        action="device_update",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device",
        entity_id=item.id,
        before=before,
        after=after,
    )
    return after


@router.patch("/api/devices/{device_id}/enabled", dependencies=[Depends(require_roles("admin"))])
def api_device_enabled(device_id: int, payload: DeviceEnabledUpdate, request: Request, db: Session = Depends(get_db)):
    item = _get_device_or_404(db, device_id)
    before = _serialize_device_overview(db, [item])[0]

    item.enabled = payload.enabled
    db.commit()
    db.refresh(item)
    after = _serialize_device_overview(db, [item])[0]

    _audit_from_request(
        request,
        action="device_enabled",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device",
        entity_id=item.id,
        before=before,
        after=after,
    )
    return after


@router.patch("/api/devices/{device_id}/permissions", dependencies=[Depends(require_roles("admin"))])
def api_device_permissions(
    device_id: int,
    payload: DevicePermissionUpdate,
    request: Request,
    db: Session = Depends(get_db),
):
    item = _get_device_or_404(db, device_id)
    before = _serialize_device_overview(db, [item])[0]
    updates = payload.model_dump(exclude_unset=True)

    if "allow_config_push" in updates:
        item.allow_config_push = updates["allow_config_push"]
    if "allow_remote_control" in updates:
        item.allow_remote_control = updates["allow_remote_control"]

    db.commit()
    db.refresh(item)
    after = _serialize_device_overview(db, [item])[0]

    _audit_from_request(
        request,
        action="device_permissions_update",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device",
        entity_id=item.id,
        before=before,
        after=after,
    )
    return after


@router.get("/api/device_groups", dependencies=[Depends(require_auth)])
def api_device_groups(
    group_code: str | None = Query(default=None, min_length=1, max_length=64),
    keyword: str | None = Query(default=None, min_length=1, max_length=100),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    q = db.query(DeviceGroup)
    if group_code:
        q = q.filter(DeviceGroup.group_code == group_code)
    if keyword:
        like = f"%{keyword}%"
        q = q.filter(
            or_(
                DeviceGroup.group_code.like(like),
                DeviceGroup.group_name.like(like),
                DeviceGroup.description.like(like),
            )
        )

    result = _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=DeviceGroup.id.asc(),
        default_limit=500,
    )
    if paginate:
        result["items"] = _serialize_group_list(db, result["items"])
        return result
    return _serialize_group_list(db, result)


@router.post("/api/device_groups", dependencies=[Depends(require_roles("admin"))])
def api_device_group_create(payload: DeviceGroupCreate, request: Request, db: Session = Depends(get_db)):
    exists = db.query(DeviceGroup.id).filter(DeviceGroup.group_code == payload.group_code).first()
    if exists is not None:
        _audit_from_request(
            request,
            action="device_group_create",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=409,
            entity_type="device_group",
            entity_id=payload.group_code,
            detail={"reason": "group_code_exists"},
        )
        raise HTTPException(status_code=409, detail="group_code already exists")

    item = DeviceGroup(
        group_code=payload.group_code,
        group_name=payload.group_name,
        description=payload.description,
    )
    db.add(item)
    db.commit()
    db.refresh(item)
    after = _serialize_group_list(db, [item])[0]

    _audit_from_request(
        request,
        action="device_group_create",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device_group",
        entity_id=item.id,
        after=after,
    )
    return after


@router.put("/api/device_groups/{group_id}", dependencies=[Depends(require_roles("admin"))])
def api_device_group_update(group_id: int, payload: DeviceGroupUpdate, request: Request, db: Session = Depends(get_db)):
    item = _get_group_or_404(db, group_id)
    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        _audit_from_request(
            request,
            action="device_group_update",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=400,
            entity_type="device_group",
            entity_id=group_id,
            detail={"reason": "no_fields_to_update"},
        )
        raise HTTPException(status_code=400, detail="no fields to update")

    before = _serialize_group_list(db, [item])[0]
    if "group_name" in updates:
        item.group_name = updates["group_name"]
    if "description" in updates:
        item.description = updates["description"]

    db.commit()
    db.refresh(item)
    after = _serialize_group_list(db, [item])[0]

    _audit_from_request(
        request,
        action="device_group_update",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device_group",
        entity_id=item.id,
        before=before,
        after=after,
    )
    return after


@router.post("/api/device_groups/{group_id}/members/{device_id}", dependencies=[Depends(require_roles("operator", "admin"))])
def api_device_group_member_add(group_id: int, device_id: int, request: Request, db: Session = Depends(get_db)):
    group = _get_group_or_404(db, group_id)
    device = _get_device_or_404(db, device_id)

    exists = (
        db.query(DeviceGroupMember.id)
        .filter(DeviceGroupMember.group_id == group_id, DeviceGroupMember.device_id == device_id)
        .first()
    )
    if exists is not None:
        _audit_from_request(
            request,
            action="device_group_member_add",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=409,
            entity_type="device_group_member",
            entity_id=f"{group_id}:{device_id}",
            detail={"reason": "member_exists"},
        )
        raise HTTPException(status_code=409, detail="device already in group")

    item = DeviceGroupMember(group_id=group_id, device_id=device_id)
    db.add(item)
    db.commit()
    db.refresh(item)

    after = {
        "id": item.id,
        "group_id": group.id,
        "group_code": group.group_code,
        "group_name": group.group_name,
        "device_id": device.id,
        "aibox_id": device.aibox_id,
        "cam_id": device.cam_id,
        "device_name": device.device_name,
    }
    _audit_from_request(
        request,
        action="device_group_member_add",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device_group_member",
        entity_id=item.id,
        after=after,
    )
    return after


@router.delete("/api/device_groups/{group_id}/members/{device_id}", dependencies=[Depends(require_roles("operator", "admin"))])
def api_device_group_member_delete(group_id: int, device_id: int, request: Request, db: Session = Depends(get_db)):
    group = _get_group_or_404(db, group_id)
    device = _get_device_or_404(db, device_id)
    item = (
        db.query(DeviceGroupMember)
        .filter(DeviceGroupMember.group_id == group_id, DeviceGroupMember.device_id == device_id)
        .first()
    )
    if item is None:
        raise HTTPException(status_code=404, detail="device group member not found")

    before = {
        "id": item.id,
        "group_id": group.id,
        "group_code": group.group_code,
        "device_id": device.id,
        "aibox_id": device.aibox_id,
        "cam_id": device.cam_id,
    }
    db.delete(item)
    db.commit()

    _audit_from_request(
        request,
        action="device_group_member_delete",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device_group_member",
        entity_id=f"{group_id}:{device_id}",
        before=before,
    )
    return {"ok": True, "group_id": group_id, "device_id": device_id}


@router.get("/api/device_overview", dependencies=[Depends(require_auth)])
def api_device_overview(
    aibox_id: str | None = Query(default=None, min_length=1, max_length=50),
    cam_id: str | None = Query(default=None, min_length=1, max_length=50),
    enabled: bool | None = Query(default=None),
    online_status: str | None = Query(default=None),
    group_code: str | None = Query(default=None, min_length=1, max_length=64),
    keyword: str | None = Query(default=None, min_length=1, max_length=100),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    if online_status is not None and online_status not in ONLINE_STATUS:
        raise HTTPException(status_code=400, detail="online_status must be on or off")

    q = db.query(Device)
    if group_code:
        q = (
            q.join(DeviceGroupMember, DeviceGroupMember.device_id == Device.id)
            .join(DeviceGroup, DeviceGroup.id == DeviceGroupMember.group_id)
            .filter(DeviceGroup.group_code == group_code)
        )
    if online_status:
        q = q.join(
            DeviceStatus,
            and_(DeviceStatus.aibox_id == Device.aibox_id, DeviceStatus.cam_id == Device.cam_id),
        ).filter(DeviceStatus.online_status == online_status)
    if aibox_id:
        q = q.filter(Device.aibox_id == aibox_id)
    if cam_id:
        q = q.filter(Device.cam_id == cam_id)
    if enabled is not None:
        q = q.filter(Device.enabled == enabled)
    if keyword:
        like = f"%{keyword}%"
        q = q.filter(
            or_(
                Device.aibox_id.like(like),
                Device.cam_id.like(like),
                Device.device_name.like(like),
                Device.device_type.like(like),
            )
        )
    q = q.distinct()

    result = _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=Device.id.asc(),
        default_limit=500,
    )
    if paginate:
        items = _serialize_device_overview(db, result["items"])
        result["items"] = items
        result["summary"] = _build_overview_summary(items)
        return result

    items = _serialize_device_overview(db, result)
    return {
        "items": items,
        "total": len(items),
        "summary": _build_overview_summary(items),
    }


@router.get("/api/device_commands", dependencies=[Depends(require_auth)])
def api_device_commands(
    device_id: int | None = Query(default=None),
    aibox_id: str | None = Query(default=None, min_length=1, max_length=50),
    cam_id: str | None = Query(default=None, min_length=1, max_length=50),
    status: str | None = Query(default=None),
    command_type: str | None = Query(default=None, min_length=1, max_length=64),
    paginate: bool = Query(default=False),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=LIST_DEFAULT_PAGE_SIZE, ge=1, le=LIST_MAX_PAGE_SIZE),
    db: Session = Depends(get_db),
):
    q = db.query(DeviceCommand)
    if device_id is not None:
        q = q.filter(DeviceCommand.device_id == device_id)
    if aibox_id:
        q = q.filter(DeviceCommand.aibox_id == aibox_id)
    if cam_id:
        q = q.filter(DeviceCommand.cam_id == cam_id)
    if status:
        q = q.filter(DeviceCommand.status == status)
    if command_type:
        q = q.filter(DeviceCommand.command_type == command_type)

    result = _paginate_query(
        q,
        paginate=paginate,
        page=page,
        page_size=page_size,
        order_by=DeviceCommand.id.desc(),
        default_limit=500,
    )
    if paginate:
        result["items"] = [orm_to_dict(item) for item in result["items"]]
        return result
    return [orm_to_dict(item) for item in result]


@router.post("/api/devices/{device_id}/config", dependencies=[Depends(require_roles("operator", "admin"))])
def api_device_config_push(
    device_id: int,
    payload: DeviceConfigPushRequest,
    request: Request,
    db: Session = Depends(get_db),
):
    device = _get_device_or_404(db, device_id)
    before = _serialize_device_overview(db, [device])[0]

    if not device.enabled:
        _audit_from_request(
            request,
            action="device_config_push",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=409,
            entity_type="device",
            entity_id=device.id,
            detail={"reason": "device_disabled"},
            before=before,
        )
        raise HTTPException(status_code=409, detail="device is disabled")

    if not device.allow_config_push:
        _audit_from_request(
            request,
            action="device_config_push",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=403,
            entity_type="device",
            entity_id=device.id,
            detail={"reason": "config_push_forbidden"},
            before=before,
        )
        raise HTTPException(status_code=403, detail="config push is disabled for this device")

    requested_by = f"{getattr(request.state, 'actor_type', 'unknown')}:{getattr(request.state, 'actor_id', '-')}"
    requested_at = _now_beijing_naive()
    topic = f"disaster_monitoring/{device.aibox_id}/config/{payload.config_name}"

    command = DeviceCommand(
        device_id=device.id,
        aibox_id=device.aibox_id,
        cam_id=device.cam_id,
        command_type="config_push",
        topic=topic,
        payload_json={},
        status="queued",
        requested_by=requested_by,
        requested_at=requested_at,
    )
    db.add(command)
    db.flush()

    message_body = {
        "command_id": command.id,
        "config_name": payload.config_name,
        "payload": payload.payload,
        "qos": payload.qos,
        "retain": payload.retain,
        "requested_at": requested_at.isoformat(),
        "requested_by": requested_by,
        "aibox_id": device.aibox_id,
        "cam_id": device.cam_id,
    }
    command.payload_json = message_body
    db.commit()
    db.refresh(command)

    try:
        publish_management_message(topic, message_body, qos=payload.qos, retain=payload.retain)
        command.status = "published"
        command.published_at = _now_beijing_naive()
        command.error_message = None
        db.commit()
        db.refresh(command)
    except Exception as ex:
        command.status = "failed"
        command.error_message = str(ex)[:500]
        db.commit()
        db.refresh(command)

        _audit_from_request(
            request,
            action="device_config_push",
            outcome=AUDIT_OUTCOME_FAIL,
            status_code=502,
            entity_type="device_command",
            entity_id=command.id,
            detail={
                "reason": "mqtt_publish_failed",
                "topic": topic,
                "error": command.error_message,
            },
            before=before,
            after=orm_to_dict(command),
        )
        raise HTTPException(status_code=502, detail="failed to publish device config")

    _audit_from_request(
        request,
        action="device_config_push",
        outcome=AUDIT_OUTCOME_SUCCESS,
        status_code=200,
        entity_type="device_command",
        entity_id=command.id,
        detail={"topic": topic, "config_name": payload.config_name},
        before=before,
        after=orm_to_dict(command),
    )
    return orm_to_dict(command)




