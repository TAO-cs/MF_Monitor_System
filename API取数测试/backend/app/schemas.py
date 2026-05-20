from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator, model_validator


class ClassificationPayload(BaseModel):
    disaster_id: str = Field(min_length=1, max_length=50)
    disaster_type: Literal["flood", "mudslide"]
    timestamp: datetime
    confidence: float = Field(ge=0.0, le=1.0)
    aibox_id: str = Field(min_length=1, max_length=50)
    cam_id: str = Field(min_length=1, max_length=50)
    image_path: str | None = Field(default=None, max_length=255)
    image_url: str | None = Field(default=None, max_length=255)


class SpeedPayload(BaseModel):
    aibox_id: str = Field(min_length=1, max_length=50)
    cam_id: str = Field(min_length=1, max_length=50)
    timestamp: datetime
    disaster_type: Literal["flood", "mudslide"]
    speed: list[float] = Field(min_length=1)

    @field_validator("speed")
    @classmethod
    def validate_speed(cls, value: list[float]) -> list[float]:
        if len(value) > 1000:
            raise ValueError("speed vector too long")
        for v in value:
            if v < 0:
                raise ValueError("speed must be non-negative")
        return value


class DeviceStatusPayload(BaseModel):
    aibox_id: str = Field(min_length=1, max_length=50)
    cam_id: str = Field(min_length=1, max_length=50)
    online_status: Literal["on", "off"]
    timestamp: datetime


class DeviceBase(BaseModel):
    aibox_id: str = Field(min_length=1, max_length=50)
    cam_id: str = Field(min_length=1, max_length=50)
    device_name: str = Field(min_length=1, max_length=100)
    device_type: str = Field(default="monitor_node", min_length=1, max_length=50)
    enabled: bool = True
    allow_config_push: bool = True
    allow_remote_control: bool = False
    metadata_json: dict[str, Any] = Field(default_factory=dict)
    location: str | None = Field(default=None, min_length=1, max_length=200)
    latitude: float | None = None
    longitude: float | None = None

    @field_validator("metadata_json")
    @classmethod
    def validate_metadata_json(cls, value: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(value, Mapping):
            raise ValueError("metadata_json must be an object")
        return dict(value)

    @model_validator(mode="after")
    def validate_location_bundle(self):
        flags = [self.location is not None, self.latitude is not None, self.longitude is not None]
        if any(flags) and not all(flags):
            raise ValueError("location, latitude and longitude must be provided together")
        return self


class DeviceCreate(DeviceBase):
    pass


class DeviceUpdate(BaseModel):
    device_name: str | None = Field(default=None, min_length=1, max_length=100)
    device_type: str | None = Field(default=None, min_length=1, max_length=50)
    enabled: bool | None = None
    allow_config_push: bool | None = None
    allow_remote_control: bool | None = None
    metadata_json: dict[str, Any] | None = None
    location: str | None = Field(default=None, min_length=1, max_length=200)
    latitude: float | None = None
    longitude: float | None = None

    @field_validator("metadata_json")
    @classmethod
    def validate_metadata_json(cls, value: dict[str, Any] | None) -> dict[str, Any] | None:
        if value is None:
            return None
        if not isinstance(value, Mapping):
            raise ValueError("metadata_json must be an object")
        return dict(value)

    @model_validator(mode="after")
    def validate_location_bundle(self):
        flags = [self.location is not None, self.latitude is not None, self.longitude is not None]
        if any(flags) and not all(flags):
            raise ValueError("location, latitude and longitude must be provided together")
        return self


class DeviceEnabledUpdate(BaseModel):
    enabled: bool


class DevicePermissionUpdate(BaseModel):
    allow_config_push: bool | None = None
    allow_remote_control: bool | None = None

    @model_validator(mode="after")
    def validate_any_field(self):
        if self.allow_config_push is None and self.allow_remote_control is None:
            raise ValueError("at least one permission field must be provided")
        return self


class DeviceGroupBase(BaseModel):
    group_name: str = Field(min_length=1, max_length=100)
    description: str | None = Field(default=None, max_length=255)


class DeviceGroupCreate(DeviceGroupBase):
    group_code: str = Field(min_length=1, max_length=64)


class DeviceGroupUpdate(BaseModel):
    group_name: str | None = Field(default=None, min_length=1, max_length=100)
    description: str | None = Field(default=None, max_length=255)

    @model_validator(mode="after")
    def validate_any_field(self):
        if self.group_name is None and self.description is None:
            raise ValueError("at least one field must be provided")
        return self


class DeviceConfigPushRequest(BaseModel):
    config_name: str = Field(min_length=1, max_length=64)
    payload: dict[str, Any] = Field(default_factory=dict)
    qos: int = Field(default=1, ge=0, le=2)
    retain: bool = False

    @field_validator("payload")
    @classmethod
    def validate_payload(cls, value: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(value, Mapping):
            raise ValueError("payload must be an object")
        return dict(value)


class AlarmRuleBase(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    event_type: Literal["classification", "speed", "device_status"]
    severity: Literal["low", "medium", "high", "critical"] = "medium"
    enabled: bool = True
    cooldown_seconds: int = Field(ge=0, le=86400, default=300)
    condition_json: dict[str, Any] = Field(default_factory=dict)

    @field_validator("condition_json")
    @classmethod
    def validate_condition_json(cls, value: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(value, Mapping):
            raise ValueError("condition_json must be an object")
        return dict(value)


class AlarmRuleCreate(AlarmRuleBase):
    rule_code: str = Field(min_length=1, max_length=64)


class AlarmRuleUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    event_type: Literal["classification", "speed", "device_status"] | None = None
    severity: Literal["low", "medium", "high", "critical"] | None = None
    enabled: bool | None = None
    cooldown_seconds: int | None = Field(default=None, ge=0, le=86400)
    condition_json: dict[str, Any] | None = None

    @field_validator("condition_json")
    @classmethod
    def validate_condition_json(cls, value: dict[str, Any] | None) -> dict[str, Any] | None:
        if value is None:
            return None
        if not isinstance(value, Mapping):
            raise ValueError("condition_json must be an object")
        return dict(value)


class AlarmRuleEnabledUpdate(BaseModel):
    enabled: bool


class NotificationChannelBase(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    channel_type: Literal["webhook"]
    enabled: bool = True
    retry_max: int = Field(default=3, ge=1, le=20)
    retry_interval_seconds: int = Field(default=30, ge=1, le=3600)
    timeout_seconds: int = Field(default=5, ge=1, le=60)
    config_json: dict[str, Any] = Field(default_factory=dict)

    @field_validator("config_json")
    @classmethod
    def validate_channel_config_json(cls, value: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(value, Mapping):
            raise ValueError("config_json must be an object")
        return dict(value)


class NotificationChannelCreate(NotificationChannelBase):
    channel_code: str = Field(min_length=1, max_length=64)


class NotificationChannelUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    channel_type: Literal["webhook"] | None = None
    enabled: bool | None = None
    retry_max: int | None = Field(default=None, ge=1, le=20)
    retry_interval_seconds: int | None = Field(default=None, ge=1, le=3600)
    timeout_seconds: int | None = Field(default=None, ge=1, le=60)
    config_json: dict[str, Any] | None = None

    @field_validator("config_json")
    @classmethod
    def validate_channel_config_json(cls, value: dict[str, Any] | None) -> dict[str, Any] | None:
        if value is None:
            return None
        if not isinstance(value, Mapping):
            raise ValueError("config_json must be an object")
        return dict(value)


class NotificationChannelEnabledUpdate(BaseModel):
    enabled: bool


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=128)


class PlatformUserCreate(BaseModel):
    username: str = Field(min_length=3, max_length=64)
    display_name: str = Field(min_length=1, max_length=100)
    password: str = Field(min_length=8, max_length=128)
    role: Literal["admin", "operator", "viewer"] = "viewer"
    enabled: bool = True


class PlatformUserUpdate(BaseModel):
    display_name: str | None = Field(default=None, min_length=1, max_length=100)
    password: str | None = Field(default=None, min_length=8, max_length=128)
    role: Literal["admin", "operator", "viewer"] | None = None
    enabled: bool | None = None

    @model_validator(mode="after")
    def validate_any_field(self):
        if self.display_name is None and self.password is None and self.role is None and self.enabled is None:
            raise ValueError("at least one field must be provided")
        return self
