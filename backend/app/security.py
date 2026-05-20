from __future__ import annotations

import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import Depends, Header, HTTPException, Request
from sqlalchemy.orm import Session

from .audit_service import record_audit_event
from .config import Settings
from .db import get_db
from .models import PlatformSession, PlatformUser
from .observability import get_request_id

settings = Settings()
BEIJING_TZ = timezone(timedelta(hours=8))
ROLE_ORDER = ("viewer", "operator", "admin")
ROLE_LABELS = {
    "viewer": "查看员",
    "operator": "值守员",
    "admin": "管理员",
}
ROLE_CAPABILITIES = {
    "viewer": {
        "dashboard": True,
        "devices_read": True,
        "devices_operate": False,
        "devices_manage": False,
        "alarms_read": True,
        "alarms_operate": False,
        "alarms_manage": False,
        "reports": True,
        "users_manage": False,
        "system_manage": False,
    },
    "operator": {
        "dashboard": True,
        "devices_read": True,
        "devices_operate": True,
        "devices_manage": False,
        "alarms_read": True,
        "alarms_operate": True,
        "alarms_manage": False,
        "reports": True,
        "users_manage": False,
        "system_manage": False,
    },
    "admin": {
        "dashboard": True,
        "devices_read": True,
        "devices_operate": True,
        "devices_manage": True,
        "alarms_read": True,
        "alarms_operate": True,
        "alarms_manage": True,
        "reports": True,
        "users_manage": True,
        "system_manage": True,
    },
}


@dataclass
class AuthContext:
    actor_type: str
    actor_id: str
    role: str
    username: str
    display_name: str
    user_id: int | None = None
    via_api_key: bool = False

    @property
    def capabilities(self) -> dict[str, bool]:
        base = ROLE_CAPABILITIES.get(self.role, ROLE_CAPABILITIES["viewer"])
        if self.via_api_key:
            return ROLE_CAPABILITIES["admin"].copy()
        return base.copy()


def _now_beijing() -> datetime:
    return datetime.now(BEIJING_TZ)


def _now_beijing_naive() -> datetime:
    return _now_beijing().replace(tzinfo=None)


def _fingerprint(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]


def hash_password(password: str, *, salt: str | None = None, iterations: int = 120_000) -> str:
    actual_salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        actual_salt.encode("utf-8"),
        iterations,
    ).hex()
    return f"pbkdf2_sha256${iterations}${actual_salt}${digest}"



def verify_password(password: str, stored_hash: str) -> bool:
    try:
        algorithm, iterations, salt, digest = stored_hash.split("$", 3)
    except ValueError:
        return False

    if algorithm != "pbkdf2_sha256":
        return False

    try:
        rounds = int(iterations)
    except ValueError:
        return False

    candidate = hash_password(password, salt=salt, iterations=rounds)
    return hmac.compare_digest(candidate, stored_hash)



def generate_session_token() -> str:
    return secrets.token_urlsafe(32)



def hash_session_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()



def serialize_platform_user(user: PlatformUser) -> dict[str, Any]:
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "role": user.role,
        "role_label": ROLE_LABELS.get(user.role, user.role),
        "enabled": bool(user.enabled),
        "last_login_at": user.last_login_at.isoformat() if user.last_login_at else None,
        "created_at": user.created_at.isoformat() if user.created_at else None,
        "updated_at": user.updated_at.isoformat() if user.updated_at else None,
        "capabilities": ROLE_CAPABILITIES.get(user.role, ROLE_CAPABILITIES["viewer"]).copy(),
    }



def _set_request_actor(request: Request, context: AuthContext) -> None:
    request.state.actor_type = context.actor_type
    request.state.actor_id = context.actor_id
    request.state.actor_role = context.role
    request.state.actor_name = context.display_name
    request.state.auth_context = context



def ensure_default_platform_users(db: Session) -> None:
    username = settings.platform_admin_username.strip() or "ninh"
    password = settings.platform_admin_password.strip() or "ninh1122"
    display_name = settings.platform_admin_display_name.strip() or "平台管理员"

    user = db.query(PlatformUser).filter(PlatformUser.username == username).first()
    changed = False

    if user is None:
        user = PlatformUser(
            username=username,
            display_name=display_name,
            password_hash=hash_password(password),
            role="admin",
            enabled=True,
            last_login_at=None,
        )
        db.add(user)
        changed = True
    else:
        if user.display_name != display_name:
            user.display_name = display_name
            changed = True
        if user.role != "admin":
            user.role = "admin"
            changed = True
        if not user.enabled:
            user.enabled = True
            changed = True
        if not verify_password(password, user.password_hash):
            user.password_hash = hash_password(password)
            changed = True

    if changed:
        db.commit()

def _authenticate_api_key(request: Request, token: str) -> AuthContext | None:
    is_valid = any(hmac.compare_digest(token, key) for key in settings.active_api_keys)
    if not is_valid:
        return None

    return AuthContext(
        actor_type="api_key",
        actor_id=_fingerprint(token),
        role="admin",
        username="system_api_key",
        display_name="系统访问密钥",
        user_id=None,
        via_api_key=True,
    )



def _authenticate_session(db: Session, token: str) -> AuthContext | None:
    token_hash = hash_session_token(token)
    now = _now_beijing_naive()
    session = (
        db.query(PlatformSession, PlatformUser)
        .join(PlatformUser, PlatformUser.id == PlatformSession.user_id)
        .filter(PlatformSession.token_hash == token_hash)
        .first()
    )
    if session is None:
        return None

    session_row, user = session
    if session_row.revoked_at is not None or session_row.expires_at < now:
        return None
    if not user.enabled:
        return None

    return AuthContext(
        actor_type="user",
        actor_id=user.username,
        role=user.role,
        username=user.username,
        display_name=user.display_name,
        user_id=user.id,
        via_api_key=False,
    )



def require_auth(
    request: Request,
    db: Session = Depends(get_db),
    authorization: str | None = Header(default=None),
) -> AuthContext:
    ip = request.client.host if request.client else "-"

    if not authorization:
        request.state.actor_type = "anonymous"
        request.state.actor_id = "-"
        raise HTTPException(status_code=401, detail="Missing Authorization header")

    prefix = "Bearer "
    if not authorization.startswith(prefix):
        request.state.actor_type = "anonymous"
        request.state.actor_id = "-"
        raise HTTPException(status_code=401, detail="Invalid Authorization format")

    token = authorization[len(prefix):].strip()
    if not token:
        request.state.actor_type = "anonymous"
        request.state.actor_id = "-"
        raise HTTPException(status_code=401, detail="Invalid API key")

    context = _authenticate_api_key(request, token)
    if context is None:
        context = _authenticate_session(db, token)

    if context is None:
        request.state.actor_type = "api_key"
        request.state.actor_id = _fingerprint(token)
        raise HTTPException(status_code=401, detail="Invalid API key")

    _set_request_actor(request, context)
    return context



def require_roles(*allowed_roles: str):
    allowed = {item for item in allowed_roles if item in ROLE_ORDER}

    def dependency(context: AuthContext = Depends(require_auth)) -> AuthContext:
        if context.via_api_key:
            return context
        if context.role not in allowed:
            raise HTTPException(status_code=403, detail="Permission denied")
        return context

    return dependency



def issue_user_session(
    db: Session,
    user: PlatformUser,
    *,
    client_ip: str | None = None,
    user_agent: str | None = None,
) -> tuple[str, PlatformSession]:
    token = generate_session_token()
    now = _now_beijing_naive()
    session = PlatformSession(
        user_id=user.id,
        token_hash=hash_session_token(token),
        client_ip=(client_ip or "-")[:64],
        user_agent=(user_agent or "-")[:255],
        expires_at=now + timedelta(hours=max(1, settings.platform_session_hours)),
        revoked_at=None,
        last_used_at=now,
    )
    user.last_login_at = now
    db.add(session)
    db.add(user)
    db.commit()
    db.refresh(session)
    db.refresh(user)
    return token, session



def revoke_session_token(db: Session, token: str) -> bool:
    session = db.query(PlatformSession).filter(PlatformSession.token_hash == hash_session_token(token)).first()
    if session is None:
        return False
    if session.revoked_at is None:
        session.revoked_at = _now_beijing_naive()
        db.add(session)
        db.commit()
    return True



def record_auth_audit(
    *,
    request: Request,
    action: str,
    outcome: str,
    status_code: int,
    actor_type: str,
    actor_id: str,
    detail: dict[str, Any] | None = None,
    entity_type: str | None = None,
    entity_id: str | int | None = None,
) -> None:
    record_audit_event(
        request_id=get_request_id(),
        actor_type=actor_type,
        actor_id=actor_id,
        action=action,
        outcome=outcome,
        path=request.url.path,
        method=request.method,
        status_code=status_code,
        client_ip=request.client.host if request.client else "-",
        detail=detail,
        entity_type=entity_type,
        entity_id=entity_id,
    )
