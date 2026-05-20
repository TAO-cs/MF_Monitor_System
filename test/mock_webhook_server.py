from __future__ import annotations

import argparse
import json
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

state_lock = threading.Lock()
request_count = 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Mock webhook receiver for P1-2 verification")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--out", required=True)
    parser.add_argument("--fail-first", type=int, default=0)
    return parser.parse_args()


class Handler(BaseHTTPRequestHandler):
    server_version = "MFMockWebhook/1.0"

    def _write_json(self, code: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._write_json(200, {"ok": True})
            return
        self._write_json(404, {"ok": False, "detail": "not found"})

    def do_POST(self):
        global request_count

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        text = raw.decode("utf-8", errors="replace")
        try:
            payload = json.loads(text)
        except Exception:
            payload = {"raw": text}

        with state_lock:
            request_count += 1
            current = request_count

        line = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "path": self.path,
            "count": current,
            "payload": payload,
        }

        out_path = Path(self.server.out_file)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")

        if current <= self.server.fail_first:
            self._write_json(500, {"ok": False, "detail": "mock fail first"})
            return

        self._write_json(200, {"ok": True, "count": current})

    def log_message(self, _format, *_args):
        return


class Server(ThreadingHTTPServer):
    def __init__(self, addr, handler, out_file: str, fail_first: int):
        super().__init__(addr, handler)
        self.out_file = out_file
        self.fail_first = fail_first


def main() -> None:
    args = parse_args()
    srv = Server((args.host, args.port), Handler, out_file=args.out, fail_first=max(args.fail_first, 0))
    print(f"mock webhook listening on http://{args.host}:{args.port}, out={args.out}, fail_first={args.fail_first}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
