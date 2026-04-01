from __future__ import annotations

import argparse
import json
import random
import time
from datetime import datetime

import paho.mqtt.client as mqtt


def build_payload(device_code: str) -> dict:
    return {
        "device_code": device_code,
        "trace_id": f"sim-{int(time.time() * 1000)}",
        "event_time": datetime.utcnow().isoformat() + "Z",
        "is_online": True,
        "battery_level": round(random.uniform(30, 100), 2),
        "signal_strength": random.randint(40, 100),
        "metrics": [
            {"key": "rainfall", "value": round(random.uniform(0, 120), 2), "unit": "mm"},
            {"key": "water_level", "value": round(random.uniform(0.1, 6.5), 2), "unit": "m"},
            {"key": "soil_moisture", "value": round(random.uniform(10, 90), 2), "unit": "%"},
        ],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--device", default="DEV-001")
    parser.add_argument("--interval", type=int, default=3)
    args = parser.parse_args()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"sim-{args.device}")
    client.connect(args.host, args.port, keepalive=60)
    client.loop_start()

    topic = f"mf/{args.device}/telemetry"
    print(f"publishing to {topic}")

    try:
        while True:
            payload = build_payload(args.device)
            client.publish(topic, json.dumps(payload), qos=1)
            print(payload)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
