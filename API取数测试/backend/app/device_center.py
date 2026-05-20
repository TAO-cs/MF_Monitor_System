from __future__ import annotations

from .models import Device, DeviceLocation, DeviceStatus, DisasterData, SpeedData

DEFAULT_DEVICE_TYPE = "monitor_node"


def ensure_device_record(db, aibox_id: str, cam_id: str, *, device_name: str | None = None, device_type: str | None = None) -> Device:
    item = (
        db.query(Device)
        .filter(Device.aibox_id == aibox_id, Device.cam_id == cam_id)
        .first()
    )
    if item is None:
        item = Device(
            aibox_id=aibox_id,
            cam_id=cam_id,
            device_name=device_name or f"{aibox_id}-{cam_id}",
            device_type=device_type or DEFAULT_DEVICE_TYPE,
            enabled=True,
            allow_config_push=True,
            allow_remote_control=False,
            metadata_json={},
        )
        db.add(item)
        db.flush()
        return item

    updated = False
    if device_name and item.device_name != device_name:
        item.device_name = device_name
        updated = True
    if device_type and item.device_type != device_type:
        item.device_type = device_type
        updated = True
    if item.metadata_json is None:
        item.metadata_json = {}
        updated = True
    if updated:
        db.flush()
    return item


def ensure_device_registry_defaults(db) -> None:
    seen: set[tuple[str, str]] = set()
    source_models = (DeviceLocation, DeviceStatus, DisasterData, SpeedData)

    for model in source_models:
        rows = db.query(model.aibox_id, model.cam_id).distinct().all()
        for aibox_id, cam_id in rows:
            if not aibox_id or not cam_id:
                continue
            seen.add((aibox_id, cam_id))

    changed = False
    for aibox_id, cam_id in sorted(seen):
        exists = (
            db.query(Device.id)
            .filter(Device.aibox_id == aibox_id, Device.cam_id == cam_id)
            .first()
        )
        if exists is None:
            ensure_device_record(db, aibox_id, cam_id)
            changed = True

    if changed:
        db.commit()
