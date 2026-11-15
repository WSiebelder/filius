#!/usr/bin/env python3
"""Local registration-token broker; the PAT never leaves the host."""

import http.server
import json
import math
import os
from pathlib import Path
import re
import socket
import socketserver
import stat
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host-control"))
from controller import ControlError, Host, atomic_json, safe_error


GRANT_SECONDS = 300
REQUEST_WINDOW = 60
REQUEST_LIMIT = 10
INSTANCE = re.compile(r"[a-f0-9]{32}")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")


class Rejected(ControlError):
    def __init__(self, message, status=403):
        super().__init__(message)
        self.status = status


class Broker:
    def __init__(self, host):
        self.host = host
        self.path = host.state_dir / "token-broker.json"

    def load(self):
        if not self.path.exists():
            return {"grants": {}, "attempts": []}
        try:
            value = json.loads(self.path.read_text())
            if not isinstance(value["grants"], dict) or not isinstance(value["attempts"], list):
                raise ValueError()
            if any(type(timestamp) not in (int, float) or not math.isfinite(timestamp)
                   for timestamp in value["attempts"]):
                raise ValueError()
            for instance, grant in value["grants"].items():
                if (
                    not INSTANCE.fullmatch(instance)
                    or grant["repository"] != self.host.repository
                    or not NAME.fullmatch(grant["name"])
                    or grant["role"] not in ("build", "deploy", "orchestration")
                    or type(grant["consumed"]) is not bool
                    or type(grant["created"]) not in (int, float)
                    or not math.isfinite(grant["created"])
                ):
                    raise ValueError()
            return value
        except (OSError, ValueError, KeyError, TypeError):
            raise ControlError("Invalid token-broker state; refusing to reset the request guard")

    def authorize(self, repository, name, role):
        if repository != self.host.repository or not NAME.fullmatch(name):
            raise ControlError("Runner repository/name does not match installed broker configuration")
        if role not in ("build", "deploy", "orchestration"):
            raise ControlError("Unknown runner role")
        now = time.time()
        with self.host.lock("token-broker"):
            state = self.load()
            state["grants"] = {
                key: value for key, value in state["grants"].items()
                if now - value["created"] < GRANT_SECONDS
            }
            if len(state["grants"]) >= 1000:
                raise ControlError("Too many pending runner grants")
            instance = uuid.uuid4().hex
            state["grants"][instance] = {
                "repository": repository, "name": name, "role": role,
                "created": now, "consumed": False,
            }
            atomic_json(self.path, state)
            return instance

    def revoke(self, instance):
        if not INSTANCE.fullmatch(instance):
            raise ControlError("Invalid runner instance")
        with self.host.lock("token-broker"):
            state = self.load()
            state["grants"].pop(instance, None)
            atomic_json(self.path, state)

    def issue(self, instance, repository, name):
        if not isinstance(instance, str) or not INSTANCE.fullmatch(instance):
            raise Rejected("Invalid runner instance")
        now = time.time()
        with self.host.lock("token-broker"):
            state = self.load()
            grant = state["grants"].get(instance)
            if not grant or grant["repository"] != repository or grant["name"] != name:
                raise Rejected("No matching host-authorized runner grant")
            if grant["consumed"]:
                raise Rejected("This runner's one-shot token request was already consumed", 409)
            if now - grant["created"] >= GRANT_SECONDS:
                raise Rejected("Runner startup grant expired")
            # Consume before contacting GitHub, including failed/lost requests.
            grant["consumed"] = True
            state["attempts"] = [timestamp for timestamp in state["attempts"]
                                 if timestamp > now - REQUEST_WINDOW]
            limited = len(state["attempts"]) >= REQUEST_LIMIT
            if not limited:
                state["attempts"].append(now)
            atomic_json(self.path, state)
        if limited:
            raise Rejected("Token request cooldown: at most 10 GitHub attempts per minute", 429)
        try:
            response = self.host.api().request("/actions/runners/registration-token", "POST")
        except (ControlError, OSError):
            raise Rejected("GitHub token request failed; inspect host credentials, permissions and rate limits", 502) from None
        token = response.get("token")
        if not isinstance(token, str) or not token:
            raise Rejected("GitHub returned no registration token", 502)
        return {"token": token}


class Handler(http.server.BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(10)
        super().setup()

    def log_message(self, format, *args):
        # Responses and request bodies can contain registration credentials.
        pass

    def reply(self, status, value):
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"ok": True})
        else:
            self.reply(404, {"error": "Unknown broker operation"})

    def do_POST(self):
        if self.path != "/token":
            self.reply(404, {"error": "Unknown broker operation"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 2048:
                raise Rejected("Invalid request length", 400)
            value = json.loads(self.rfile.read(length))
            if not isinstance(value, dict) or set(value) != {"instance", "repository", "name"}:
                raise Rejected("Expected runner instance, repository and name", 400)
            result = self.server.broker.issue(value["instance"], value["repository"], value["name"])
        except Rejected as error:
            print("Token broker rejected request: " + str(error), file=sys.stderr, flush=True)
            self.reply(error.status, {"error": str(error)})
        except (ValueError, TypeError):
            self.reply(400, {"error": "Invalid broker request"})
        except (ControlError, OSError):
            self.reply(503, {"error": "Token broker unavailable; inspect its host journal"})
        else:
            self.reply(200, result)


class Server(socketserver.UnixStreamServer):
    def __init__(self, path, broker):
        self.broker = broker
        super().__init__(str(path), Handler)

    def handle_error(self, request, client_address):
        print("Token broker connection failed", file=sys.stderr, flush=True)


def serve(host):
    broker = Broker(host)
    with host.lock("token-broker"):
        broker.load()
    directory = Path(os.environ.get("FILIUS_TOKEN_BROKER_DIR", str(host.root / "token-broker")))
    path = directory / "broker.sock"
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != 0:
            raise ControlError("Refusing to replace an unexpected broker socket path")
        with socket.socket(socket.AF_UNIX) as probe:
            probe.settimeout(1)
            try:
                probe.connect(str(path))
            except (ConnectionRefusedError, FileNotFoundError):
                path.unlink(missing_ok=True)
            else:
                raise ControlError("A token broker is already listening")
    with Server(path, broker) as server:
        # The host parent is private; mapped container UIDs need socket access.
        os.chmod(path, 0o666)
        print("Token broker listening on its local Unix socket", flush=True)
        server.serve_forever()


def main():
    if os.geteuid() != 0:
        raise ControlError("Token-broker host commands require root")
    host = Host()
    arguments = sys.argv[1:]
    broker = Broker(host)
    if arguments == ["serve"]:
        serve(host)
    elif len(arguments) == 4 and arguments[0] == "authorize":
        print(broker.authorize(*arguments[1:]))
    elif len(arguments) == 2 and arguments[0] == "revoke":
        broker.revoke(arguments[1])
    else:
        raise ControlError("Usage: broker.py serve | authorize REPOSITORY NAME ROLE | revoke INSTANCE")


if __name__ == "__main__":
    try:
        main()
    except (ControlError, OSError) as error:
        print(safe_error(error), file=sys.stderr)
        sys.exit(1)
