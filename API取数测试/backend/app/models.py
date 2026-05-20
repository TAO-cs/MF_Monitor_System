from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Enum,
    Float,
    Integer,
    JSON,
    Numeric,
    String,
    UniqueConstraint,
    func,
)

from .db import Base


class DisasterData(Base):
    __tablename__ = "disaster_data"

    id = Column(Integer, primary_key=True, index=True)
    disaster_id = Column(String(50), nullable=False, index=True)
    aibox_id = Column(String(50), nullable=False, index=True)
    cam_id = Column(String(50), nullable=False, index=True)
    disaster_type = Column(Enum("flood", "mudslide", name="disaster_type"), nullable=False)
    timestamp = Column(DateTime, nullable=False, index=True)
    confidence = Column(Numeric(5, 4), nullable=False)
    image_path = Column(String(255), nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())


class SpeedData(Base):
    __tablename__ = "speed_data"

    id = Column(Integer, primary_key=True, index=True)
    aibox_id = Column(String(50), nullable=False, index=True)
    cam_id = Column(String(50), nullable=False, index=True)
    disaster_type = Column(Enum("flood", "mudslide", name="speed_disaster_type"), nullable=False)
    timestamp = Column(DateTime, nullable=False, index=True)
    speed = Column(JSON, nullable=False)
    created_at = Column(DateTime, nullable=False, server_default=func.now())


class DeviceLocation(Base):
    __tablename__ = "device_location"

    id = Column(Integer, primary_key=True, index=True)
    aibox_id = Column(String(50), nullable=False, index=True)
    cam_id = Column(String(50), nullable=False, index=True)
    location = Column(String(200), nullable=False)
    latitude = Column(Float, nullable=False)
    longitude = Column(Float, nullable=False)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class DeviceStatus(Base):
    __tablename__ = "device_status"

    id = Column(Integer, primary_key=True, index=True)
    aibox_id = Column(String(50), nullable=False, index=True)
    cam_id = Column(String(50), nullable=False, index=True)
    online_status = Column(Enum("on", "off", name="online_status"), nullable=False)
    last_update = Column(DateTime, nullable=False, index=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (
        UniqueConstraint("aibox_id", "cam_id", name="uk_device_identity"),
    )

    id = Column(Integer, primary_key=True, index=True)
    aibox_id = Column(String(50), nullable=False, index=True)
    cam_id = Column(String(50), nullable=False, index=True)
    device_name = Column(String(100), nullable=False)
    device_type = Column(String(50), nullable=False, index=True, default="monitor_node", server_default="monitor_node")
    enabled = Column(Boolean, nullable=False, default=True, server_default="1", index=True)
    allow_config_push = Column(Boolean, nullable=False, default=True, server_default="1", index=True)
    allow_remote_control = Column(Boolean, nullable=False, default=False, server_default="0")
    metadata_json = Column(JSON, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class DeviceGroup(Base):
    __tablename__ = "device_groups"

    id = Column(Integer, primary_key=True, index=True)
    group_code = Column(String(64), nullable=False, unique=True, index=True)
    group_name = Column(String(100), nullable=False)
    description = Column(String(255), nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class DeviceGroupMember(Base):
    __tablename__ = "device_group_members"
    __table_args__ = (
        UniqueConstraint("group_id", "device_id", name="uk_device_group_member"),
    )

    id = Column(Integer, primary_key=True, index=True)
    group_id = Column(Integer, nullable=False, index=True)
    device_id = Column(Integer, nullable=False, index=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())


class DeviceCommand(Base):
    __tablename__ = "device_commands"

    id = Column(Integer, primary_key=True, index=True)
    device_id = Column(Integer, nullable=False, index=True)
    aibox_id = Column(String(50), nullable=False, index=True)
    cam_id = Column(String(50), nullable=False, index=True)
    command_type = Column(String(64), nullable=False, index=True, default="config_push", server_default="config_push")
    topic = Column(String(255), nullable=False)
    payload_json = Column(JSON, nullable=False)
    status = Column(
        Enum("queued", "published", "failed", name="device_command_status"),
        nullable=False,
        default="queued",
        server_default="queued",
        index=True,
    )
    requested_by = Column(String(128), nullable=False)
    requested_at = Column(DateTime, nullable=False, index=True)
    published_at = Column(DateTime, nullable=True)
    error_message = Column(String(500), nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class AlarmRule(Base):
    __tablename__ = "alarm_rules"

    id = Column(Integer, primary_key=True, index=True)
    rule_code = Column(String(64), nullable=False, unique=True, index=True)
    name = Column(String(100), nullable=False)
    event_type = Column(
        Enum("classification", "speed", "device_status", name="alarm_event_type"),
        nullable=False,
        index=True,
    )
    severity = Column(
        Enum("low", "medium", "high", "critical", name="alarm_severity"),
        nullable=False,
        default="medium",
    )
    enabled = Column(Boolean, nullable=False, default=True, server_default="1", index=True)
    cooldown_seconds = Column(Integer, nullable=False, default=300)
    condition_json = Column(JSON, nullable=False)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class Alarm(Base):
    __tablename__ = "alarms"

    id = Column(Integer, primary_key=True, index=True)
    rule_code = Column(String(64), nullable=False, index=True)
    event_type = Column(
        Enum("classification", "speed", "device_status", name="alarm_instance_event_type"),
        nullable=False,
        index=True,
    )
    severity = Column(
        Enum("low", "medium", "high", "critical", name="alarm_instance_severity"),
        nullable=False,
        index=True,
    )
    status = Column(
        Enum("open", "ack", "closed", name="alarm_status"),
        nullable=False,
        default="open",
        server_default="open",
        index=True,
    )
    aibox_id = Column(String(50), nullable=False, index=True)
    cam_id = Column(String(50), nullable=False, index=True)
    source_ref = Column(String(80), nullable=True, index=True)
    trigger_value = Column(JSON, nullable=False)
    triggered_at = Column(DateTime, nullable=False, index=True)
    recovered_at = Column(DateTime, nullable=True, index=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class NotificationChannel(Base):
    __tablename__ = "notification_channels"

    id = Column(Integer, primary_key=True, index=True)
    channel_code = Column(String(64), nullable=False, unique=True, index=True)
    name = Column(String(100), nullable=False)
    channel_type = Column(
        Enum("webhook", name="notify_channel_type"),
        nullable=False,
        index=True,
    )
    enabled = Column(Boolean, nullable=False, default=False, server_default="0", index=True)
    retry_max = Column(Integer, nullable=False, default=3)
    retry_interval_seconds = Column(Integer, nullable=False, default=30)
    timeout_seconds = Column(Integer, nullable=False, default=5)
    config_json = Column(JSON, nullable=False)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class AlarmNotification(Base):
    __tablename__ = "alarm_notifications"
    __table_args__ = (
        UniqueConstraint("alarm_id", "channel_id", name="uk_alarm_channel_notification"),
    )

    id = Column(Integer, primary_key=True, index=True)
    alarm_id = Column(Integer, nullable=False, index=True)
    channel_id = Column(Integer, nullable=False, index=True)
    channel_code = Column(String(64), nullable=False, index=True)
    channel_type = Column(
        Enum("webhook", name="notify_instance_channel_type"),
        nullable=False,
        index=True,
    )
    status = Column(
        Enum("pending", "sent", "failed", name="notify_status"),
        nullable=False,
        default="pending",
        server_default="pending",
        index=True,
    )
    attempts = Column(Integer, nullable=False, default=0)
    last_error = Column(String(500), nullable=True)
    payload_json = Column(JSON, nullable=False)
    next_retry_at = Column(DateTime, nullable=True, index=True)
    last_attempt_at = Column(DateTime, nullable=True)
    sent_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id = Column(Integer, primary_key=True, index=True)
    request_id = Column(String(64), nullable=False, index=True)
    actor_type = Column(String(32), nullable=False, index=True)
    actor_id = Column(String(128), nullable=False, index=True)
    action = Column(String(64), nullable=False, index=True)
    outcome = Column(String(16), nullable=False, index=True)
    entity_type = Column(String(64), nullable=True, index=True)
    entity_id = Column(String(64), nullable=True, index=True)
    path = Column(String(255), nullable=False, index=True)
    method = Column(String(16), nullable=False, index=True)
    status_code = Column(Integer, nullable=True, index=True)
    client_ip = Column(String(64), nullable=True)
    detail_json = Column(JSON, nullable=True)
    before_json = Column(JSON, nullable=True)
    after_json = Column(JSON, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now(), index=True)


class PlatformUser(Base):
    __tablename__ = "platform_users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String(64), nullable=False, unique=True, index=True)
    display_name = Column(String(100), nullable=False)
    password_hash = Column(String(255), nullable=False)
    role = Column(
        Enum("admin", "operator", "viewer", name="platform_user_role"),
        nullable=False,
        default="viewer",
        server_default="viewer",
        index=True,
    )
    enabled = Column(Boolean, nullable=False, default=True, server_default="1", index=True)
    last_login_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class PlatformSession(Base):
    __tablename__ = "platform_sessions"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, nullable=False, index=True)
    token_hash = Column(String(64), nullable=False, unique=True, index=True)
    client_ip = Column(String(64), nullable=True)
    user_agent = Column(String(255), nullable=True)
    expires_at = Column(DateTime, nullable=False, index=True)
    revoked_at = Column(DateTime, nullable=True, index=True)
    last_used_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())
