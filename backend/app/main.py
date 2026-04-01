from __future__ import annotations

import json
from datetime import datetime

from fastapi import Depends, FastAPI, HTTPException
from sqlalchemy.orm import Session

from .config import Settings
from .db import Base, engine, get_db
from .models import CommandLog, Device, TelemetryData
from .mqtt_service import create_mqtt_client
from .schemas import CommandRequest, DeviceCreate, DeviceOut, TelemetryOut

settings = Settings()
app = FastAPI(title="MF Monitor Prototype", version="0.1.0")

Base.metadata.create_all(bind=engine)
mqtt_client = create_mqtt_client()


@app.on_event("startup")
def startup_event():
    mqtt_client.connect(settings.mqtt_broker_host, settings.mqtt_broker_port, keepalive=60)
    mqtt_client.loop_start()


@app.on_event("shutdown")
def shutdown_event():
    mqtt_client.loop_stop()
    mqtt_client.disconnect()


@app.get("/health")
def health():
    return {"status": "ok", "time": datetime.utcnow().isoformat()}


@app.post("/devices", response_model=DeviceOut)
def create_device(payload: DeviceCreate, db: Session = Depends(get_db)):
    exists = db.query(Device).filter(Device.device_code == payload.device_code).first()
    if exists:
        raise HTTPException(status_code=400, detail="device_code already exists")

    row = Device(
        device_code=payload.device_code,
        name=payload.name,
        device_type=payload.device_type,
        location=payload.location,
        is_active=True,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


@app.get("/devices", response_model=list[DeviceOut])
def list_devices(db: Session = Depends(get_db)):
    return db.query(Device).order_by(Device.id.desc()).all()


@app.get("/telemetry/latest", response_model=list[TelemetryOut])
def latest_telemetry(limit: int = 20, db: Session = Depends(get_db)):
    return db.query(TelemetryData).order_by(TelemetryData.id.desc()).limit(limit).all()


@app.post("/commands/send")
def send_command(req: CommandRequest, db: Session = Depends(get_db)):
    trace_id = f"cmd-{int(datetime.utcnow().timestamp())}"
    topic = f"mf/{req.device_code}/command/req"
    data = {
        "trace_id": trace_id,
        "command_name": req.command_name,
        "payload": req.payload,
        "event_time": datetime.utcnow().isoformat() + "Z",
    }

    mqtt_client.publish(topic, json.dumps(data, ensure_ascii=False), qos=1)

    cmd_log = CommandLog(
        device_code=req.device_code,
        command_name=req.command_name,
        request_payload=data,
        status="SENT",
        trace_id=trace_id,
        sent_at=datetime.utcnow(),
    )
    db.add(cmd_log)
    db.commit()

    return {"ok": True, "topic": topic, "trace_id": trace_id}
