from __future__ import annotations

import json
import random
import time
from datetime import datetime, timedelta, timezone

import paho.mqtt.client as mqtt

BEIJING_TZ = timezone(timedelta(hours=8))


def _now_beijing() -> datetime:
    return datetime.now(BEIJING_TZ)


def _now_iso() -> str:
    return _now_beijing().isoformat()


def build_classification_payload(aibox_id: str, cam_id: str) -> dict:
    return {
        "disaster_id": f"{_now_beijing().strftime('%Y%m%d_%H%M%S')}_{random.randint(100, 999)}",
        "disaster_type": random.choice(["flood", "mudslide"]),
        "timestamp": _now_iso(),
        "confidence": round(random.uniform(0.75, 0.99), 4),
        "aibox_id": aibox_id,
        "cam_id": cam_id,
        "image_path": f"https://storage.server/data/images/{aibox_id}/{cam_id}/{int(time.time())}.jpg",
    }


def build_speed_payload(aibox_id: str, cam_id: str) -> dict:
    return {
        "aibox_id": aibox_id,
        "cam_id": cam_id,
        "timestamp": _now_iso(),
        "disaster_type": random.choice(["flood", "mudslide"]),
        "speed": [round(random.uniform(0.5, 2.5), 2) for _ in range(4)],
    }


def build_status_payload(aibox_id: str, cam_id: str) -> dict:
    return {
        "aibox_id": aibox_id,
        "cam_id": cam_id,
        "online_status": "on",
        "timestamp": _now_iso(),
    }


def main():
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--device", default="MF001")
    parser.add_argument("--cam", default="CAM001")
    parser.add_argument("--interval", type=int, default=3)
    args = parser.parse_args()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"sim-{args.device}")
    client.connect(args.host, args.port, keepalive=60)
    client.loop_start()

    cls_topic = f"disaster_monitoring/{args.device}/classification"
    speed_topic = f"disaster_monitoring/{args.device}/speed"
    status_topic = f"disaster_monitoring/{args.device}/device_status"

    print(f"publishing to {cls_topic}, {speed_topic}, {status_topic}")

    try:
        while True:
            status_payload = build_status_payload(args.device, args.cam)
            client.publish(status_topic, json.dumps(status_payload, ensure_ascii=False), qos=1)
            print({"topic": status_topic, "payload": status_payload})

            cls_payload = build_classification_payload(args.device, args.cam)
            speed_payload = build_speed_payload(args.device, args.cam)

            client.publish(cls_topic, json.dumps(cls_payload, ensure_ascii=False), qos=0)
            client.publish(speed_topic, json.dumps(speed_payload, ensure_ascii=False), qos=0)

            print({"topic": cls_topic, "payload": cls_payload})
            print({"topic": speed_topic, "payload": speed_payload})

            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
