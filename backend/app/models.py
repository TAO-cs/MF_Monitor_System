from sqlalchemy import JSON, Boolean, Column, DateTime, Double, Integer, String, Text, func

from .db import Base


class Device(Base):
    __tablename__ = "devices"

    id = Column(Integer, primary_key=True, index=True)
    device_code = Column(String(64), unique=True, nullable=False, index=True)
    name = Column(String(128), nullable=False)
    device_type = Column(String(64), nullable=False, default="sensor")
    location = Column(String(255), nullable=True)
    is_active = Column(Boolean, nullable=False, default=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class DeviceStatus(Base):
    __tablename__ = "device_status"

    id = Column(Integer, primary_key=True, index=True)
    device_code = Column(String(64), nullable=False, unique=True, index=True)
    is_online = Column(Boolean, nullable=False, default=False)
    last_seen_at = Column(DateTime, nullable=True)
    battery_level = Column(Double, nullable=True)
    signal_strength = Column(Integer, nullable=True)
    raw_payload = Column(JSON, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())


class TelemetryData(Base):
    __tablename__ = "telemetry_data"

    id = Column(Integer, primary_key=True, index=True)
    device_code = Column(String(64), nullable=False, index=True)
    event_time = Column(DateTime, nullable=False, index=True)
    metric_key = Column(String(64), nullable=False, index=True)
    metric_value = Column(Double, nullable=False)
    unit = Column(String(32), nullable=True)
    trace_id = Column(String(64), nullable=True)
    raw_payload = Column(JSON, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())


class Alarm(Base):
    __tablename__ = "alarms"

    id = Column(Integer, primary_key=True, index=True)
    device_code = Column(String(64), nullable=False, index=True)
    alarm_type = Column(String(64), nullable=False)
    level = Column(String(16), nullable=False)
    message = Column(String(255), nullable=False)
    event_time = Column(DateTime, nullable=False, index=True)
    is_cleared = Column(Boolean, nullable=False, default=False)
    raw_payload = Column(JSON, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())


class CommandLog(Base):
    __tablename__ = "command_logs"

    id = Column(Integer, primary_key=True, index=True)
    device_code = Column(String(64), nullable=False, index=True)
    command_name = Column(String(64), nullable=False)
    request_payload = Column(JSON, nullable=True)
    response_payload = Column(JSON, nullable=True)
    status = Column(String(32), nullable=False, default="SENT")
    trace_id = Column(String(64), nullable=True)
    sent_at = Column(DateTime, nullable=False)
    responded_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
