from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field


class DeviceCreate(BaseModel):
    device_code: str
    name: str
    device_type: str = "sensor"
    location: str | None = None


class DeviceOut(BaseModel):
    device_code: str
    name: str
    device_type: str
    location: str | None
    is_active: bool

    class Config:
        from_attributes = True


class CommandRequest(BaseModel):
    device_code: str
    command_name: str
    payload: dict[str, Any] = Field(default_factory=dict)


class TelemetryOut(BaseModel):
    device_code: str
    event_time: datetime
    metric_key: str
    metric_value: float
    unit: str | None

    class Config:
        from_attributes = True
