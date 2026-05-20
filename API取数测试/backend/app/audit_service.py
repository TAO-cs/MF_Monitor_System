from __future__ import annotations

import json
import logging
from datetime import datetime
from typing import Any

from .db import SessionLocal
from .models import AuditLog

logger = logging.getLogger("mf.audit")


def _json_friendly(value: Any) -> Any:
    if value is None:
        return None

    if isinstance(value, (str, int, float, bool)):
        return value

    if isinstance(value, datetime):
        return value.isoformat()

    if isinstance(value, dict):
        return {str(k): _json_friendly(v) for k, v in value.items()}

    if isinstance(value, (list, tuple, set)):
        return [_json_friendly(v) for v in value]

    # SQLAlchemy ORM object support
    table = getattr(value, "__table__", None)
    if table is not None:
        out: dict[str, Any] = {}
        for col in table.columns:
            out[col.name] = _json_friendly(getattr(value, col.name))
        return out

    return str(value)


def _truncate_json(value: Any, limit: int = 60000) -> Any:
    if value is None:
        return None
    try:
        text = json.dumps(value, ensure_ascii=False, default=str)
    except Exception:
        text = str(value)
    if len(text) <= limit:
        return value
    return {"_truncated": True, "size": len(text), "preview": text[:limit]}


def record_audit_event(
    *,
    request_id: str,
    actor_type: str,
    actor_id: str,
    action: str,
    outcome: str,
    path: str,
    method: str,
    status_code: int | None,
    client_ip: str | None,
    entity_type: str | None = None,
    entity_id: str | int | None = None,
    detail: dict[str, Any] | None = None,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
) -> None:
    db = SessionLocal()
    try:
        detail_v = _truncate_json(_json_friendly(detail))
        before_v = _truncate_json(_json_friendly(before))
        after_v = _truncate_json(_json_friendly(after))

        db.add(
            AuditLog(
                request_id=(request_id or "-")[:64],
                actor_type=(actor_type or "unknown")[:32],
                actor_id=(actor_id or "-")[:128],
                action=(action or "unknown")[:64],
                outcome=(outcome or "unknown")[:16],
                entity_type=(entity_type or "")[:64] or None,
                entity_id=(str(entity_id)[:64] if entity_id is not None else None),
                path=(path or "")[:255],
                method=(method or "")[:16],
                status_code=status_code,
                client_ip=(client_ip or "-")[:64],
                detail_json=detail_v,
                before_json=before_v,
                after_json=after_v,
            )
        )
        db.commit()
    except Exception:
        db.rollback()
        logger.exception("audit_write_failed")
    finally:
        db.close()


def orm_to_dict(obj: Any) -> dict[str, Any] | None:
    if obj is None:
        return None
    value = _json_friendly(obj)
    if isinstance(value, dict):
        return value
    return {"value": value}
