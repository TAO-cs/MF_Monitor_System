from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv
from pydantic import BaseModel

BASE_DIR = Path(__file__).resolve().parents[2]
APP_ROOT = Path(__file__).resolve().parents[1]


def _resolve_env_file() -> tuple[str, Path]:
    app_env = os.getenv("APP_ENV", "dev").strip().lower() or "dev"
    explicit = os.getenv("ENV_FILE", "").strip()

    if explicit:
        path = Path(explicit)
        if not path.is_absolute():
            path = (BASE_DIR / path).resolve()
        return app_env, path

    specific = BASE_DIR / f".env.{app_env}"
    if specific.exists():
        return app_env, specific

    return app_env, BASE_DIR / ".env"


def _parse_csv_env(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [item.strip() for item in raw.split(",") if item and item.strip()]


def _required_or_raise(keys: list[str], env_path: Path) -> None:
    missing: list[str] = []
    for k in keys:
        v = os.getenv(k, "")
        if not v or not v.strip():
            missing.append(k)
    if missing:
        raise RuntimeError(
            "Missing required env vars in "
            f"{env_path}: {', '.join(missing)}"
        )


APP_ENV, ENV_PATH = _resolve_env_file()
load_dotenv(BASE_DIR / ".env", override=False)
if ENV_PATH.exists():
    load_dotenv(ENV_PATH, override=True)

_required_or_raise(
    [
        "DB_HOST",
        "DB_PORT",
        "DB_NAME",
        "DB_USER",
        "DB_PASSWORD",
        "MQTT_BROKER_HOST",
        "MQTT_BROKER_PORT",
        "API_KEY",
        "PLATFORM_ADMIN_USERNAME",
        "PLATFORM_ADMIN_PASSWORD",
    ],
    ENV_PATH,
)


class Settings(BaseModel):
    app_env: str = APP_ENV
    env_file: str = str(ENV_PATH)

    db_host: str = os.getenv("DB_HOST", "127.0.0.1")
    db_port: int = int(os.getenv("DB_PORT", "3306"))
    db_name: str = os.getenv("DB_NAME", "mf_monitor")
    db_user: str = os.getenv("DB_USER", "mf_user")
    db_password: str = os.getenv("DB_PASSWORD", "mf_pass123")

    mqtt_broker_host: str = os.getenv("MQTT_BROKER_HOST", "127.0.0.1")
    mqtt_broker_port: int = int(os.getenv("MQTT_BROKER_PORT", "1883"))
    mqtt_username: str = os.getenv("MQTT_USERNAME", "")
    mqtt_password: str = os.getenv("MQTT_PASSWORD", "")

    api_key: str = os.getenv("API_KEY", "")
    api_keys: list[str] = _parse_csv_env(os.getenv("API_KEYS", ""))
    api_keys_disabled: set[str] = set(_parse_csv_env(os.getenv("API_KEYS_DISABLED", "")) )
    platform_admin_username: str = os.getenv("PLATFORM_ADMIN_USERNAME", "")
    platform_admin_password: str = os.getenv("PLATFORM_ADMIN_PASSWORD", "")
    platform_admin_display_name: str = os.getenv("PLATFORM_ADMIN_DISPLAY_NAME", "平台管理员")
    platform_session_hours: int = int(os.getenv("PLATFORM_SESSION_HOURS", "12"))

    log_level: str = os.getenv("LOG_LEVEL", "INFO")
    notify_worker_interval_seconds: int = int(os.getenv("NOTIFY_WORKER_INTERVAL_SECONDS", "2"))
    app_instance_id: str = os.getenv("APP_INSTANCE_ID", os.getenv("HOSTNAME", "local-backend"))
    app_release_version: str = os.getenv("APP_RELEASE_VERSION", "dev-local")
    app_release_channel: str = os.getenv("APP_RELEASE_CHANNEL", "default")
    enable_ingestion: bool = os.getenv("ENABLE_INGESTION", "1") not in {"0", "false", "False"}
    evidence_upload_dir: str = os.getenv("EVIDENCE_UPLOAD_DIR", str(APP_ROOT / "evidence_uploads"))

    rate_limit_enabled: bool = os.getenv("RATE_LIMIT_ENABLED", "1") not in {"0", "false", "False"}
    rate_limit_window_seconds: int = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60"))
    rate_limit_max_requests: int = int(os.getenv("RATE_LIMIT_MAX_REQUESTS", "120"))

    idempotency_enabled: bool = os.getenv("IDEMPOTENCY_ENABLED", "1") not in {"0", "false", "False"}
    idempotency_ttl_seconds: int = int(os.getenv("IDEMPOTENCY_TTL_SECONDS", "600"))
    idempotency_max_entries: int = int(os.getenv("IDEMPOTENCY_MAX_ENTRIES", "1000"))
    idempotency_max_body_bytes: int = int(os.getenv("IDEMPOTENCY_MAX_BODY_BYTES", "1048576"))

    @property
    def active_api_keys(self) -> list[str]:
        keys: list[str] = []
        if self.api_key:
            keys.append(self.api_key)
        keys.extend(self.api_keys)

        deduped: list[str] = []
        seen: set[str] = set()
        for key in keys:
            if key not in seen:
                seen.add(key)
                deduped.append(key)

        active = [k for k in deduped if k not in self.api_keys_disabled]
        return active

    @property
    def sqlalchemy_url(self) -> str:
        return (
            f"mysql+pymysql://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}?charset=utf8mb4"
        )




