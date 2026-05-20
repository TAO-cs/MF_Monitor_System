from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from .db import get_db
from .models import PlatformUser
from .schemas import LoginRequest, PlatformUserCreate, PlatformUserUpdate
from .security import (
    AuthContext,
    ensure_default_platform_users,
    issue_user_session,
    record_auth_audit,
    require_auth,
    require_roles,
    ROLE_LABELS,
    revoke_session_token,
    serialize_platform_user,
    verify_password,
    hash_password,
)

router = APIRouter(tags=["platform-auth"])


@router.post("/api/auth/login")
def login(payload: LoginRequest, request: Request, db: Session = Depends(get_db)):
    ensure_default_platform_users(db)
    username = payload.username.strip()
    user = db.query(PlatformUser).filter(PlatformUser.username == username).first()

    if user is None or not user.enabled or not verify_password(payload.password, user.password_hash):
        record_auth_audit(
            request=request,
            action="auth_login",
            outcome="fail",
            status_code=401,
            actor_type="anonymous",
            actor_id=username or "-",
            detail={"username": username},
        )
        raise HTTPException(status_code=401, detail="Invalid username or password")

    token, session = issue_user_session(
        db,
        user,
        client_ip=request.client.host if request.client else "-",
        user_agent=request.headers.get("User-Agent", "-"),
    )
    record_auth_audit(
        request=request,
        action="auth_login",
        outcome="success",
        status_code=200,
        actor_type="user",
        actor_id=user.username,
        detail={"role": user.role, "session_id": session.id},
        entity_type="platform_user",
        entity_id=user.id,
    )
    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_in_seconds": max(1, int((session.expires_at - session.last_used_at).total_seconds())),
        "user": serialize_platform_user(user),
    }


@router.get("/api/auth/me")
def me(context: AuthContext = Depends(require_auth)):
    if context.via_api_key:
        return {
            "id": None,
            "username": context.username,
            "display_name": context.display_name,
            "role": "admin",
            "role_label": "管理员",
            "enabled": True,
            "last_login_at": None,
            "created_at": None,
            "updated_at": None,
            "capabilities": context.capabilities,
            "via_api_key": True,
        }

    return {
        "id": context.user_id,
        "username": context.username,
        "display_name": context.display_name,
        "role": context.role,
        "role_label": ROLE_LABELS.get(context.role, context.role),
        "enabled": True,
        "last_login_at": None,
        "created_at": None,
        "updated_at": None,
        "capabilities": context.capabilities,
        "via_api_key": False,
    }


@router.post("/api/auth/logout")
def logout(
    request: Request,
    context: AuthContext = Depends(require_auth),
    db: Session = Depends(get_db),
):
    authorization = (request.headers.get("Authorization") or "").strip()
    token = authorization[len("Bearer "):].strip() if authorization.startswith("Bearer ") else ""
    if not context.via_api_key and token:
        revoke_session_token(db, token)

    record_auth_audit(
        request=request,
        action="auth_logout",
        outcome="success",
        status_code=200,
        actor_type=context.actor_type,
        actor_id=context.actor_id,
        detail={"via_api_key": context.via_api_key},
        entity_type="platform_user",
        entity_id=context.user_id,
    )
    return {"ok": True}


@router.get("/api/platform_users", dependencies=[Depends(require_roles("admin"))])
def list_platform_users(db: Session = Depends(get_db)):
    ensure_default_platform_users(db)
    rows = db.query(PlatformUser).order_by(PlatformUser.id.asc()).all()
    return [serialize_platform_user(item) for item in rows]


@router.post("/api/platform_users", dependencies=[Depends(require_roles("admin"))])
def create_platform_user(
    payload: PlatformUserCreate,
    request: Request,
    context: AuthContext = Depends(require_auth),
    db: Session = Depends(get_db),
):
    exists = db.query(PlatformUser).filter(PlatformUser.username == payload.username.strip()).first()
    if exists is not None:
        raise HTTPException(status_code=409, detail="username already exists")

    user = PlatformUser(
        username=payload.username.strip(),
        display_name=payload.display_name.strip(),
        password_hash=hash_password(payload.password),
        role=payload.role,
        enabled=payload.enabled,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    record_auth_audit(
        request=request,
        action="platform_user_create",
        outcome="success",
        status_code=200,
        actor_type=context.actor_type,
        actor_id=context.actor_id,
        detail={"role": user.role},
        entity_type="platform_user",
        entity_id=user.id,
    )
    return serialize_platform_user(user)


@router.patch("/api/platform_users/{user_id}", dependencies=[Depends(require_roles("admin"))])
def update_platform_user(
    user_id: int,
    payload: PlatformUserUpdate,
    request: Request,
    context: AuthContext = Depends(require_auth),
    db: Session = Depends(get_db),
):
    user = db.query(PlatformUser).filter(PlatformUser.id == user_id).first()
    if user is None:
        raise HTTPException(status_code=404, detail="platform user not found")

    before = serialize_platform_user(user)
    update_data = payload.model_dump(exclude_unset=True)
    if "display_name" in update_data:
        user.display_name = update_data["display_name"].strip()
    if "role" in update_data:
        user.role = update_data["role"]
    if "enabled" in update_data:
        user.enabled = bool(update_data["enabled"])
    if "password" in update_data and update_data["password"]:
        user.password_hash = hash_password(update_data["password"])

    db.add(user)
    db.commit()
    db.refresh(user)

    record_auth_audit(
        request=request,
        action="platform_user_update",
        outcome="success",
        status_code=200,
        actor_type=context.actor_type,
        actor_id=context.actor_id,
        detail={"updated_fields": sorted(update_data.keys())},
        entity_type="platform_user",
        entity_id=user.id,
    )
    return {
        "before": before,
        "after": serialize_platform_user(user),
    }

