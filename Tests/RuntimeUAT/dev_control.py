#!/usr/bin/env python3
"""Client for the #3765 dev control door in a RUNNING dev build.

The app side is `Sources/EnviousWisprAppKit/App/Debug/DevControl/DevControlDoor.swift`
(DEBUG builds only). It listens on `/tmp/ew-dev-control-<uid>/<pid>.sock` and answers one
newline-delimited JSON object per request:

    request  {"id": "<client id>", "cmd": "ping", "args": {...}}
    reply    {"id", "ok": true, "result": {...}} or {"id", "ok": false, "error": {...}}
             plus always "pid", "launch", "executable", "door"

Socket commands use the standard library only, so this module imports `json`, `os`,
`socket` and `uuid` and nothing else.
"""

import json
import os
import socket
import uuid

PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 1 << 20


class DoorError(Exception):
    """The door could not be reached or answered with something that is not a reply."""


def socket_path(pid, uid=None):
    uid = os.geteuid() if uid is None else uid
    return f"/tmp/ew-dev-control-{uid}/{int(pid)}.sock"


def _read_frame(sock, buffer):
    while b"\n" not in buffer:
        chunk = sock.recv(65536)
        if not chunk:
            raise DoorError("door closed the connection before replying")
        buffer += chunk
        if len(buffer) > MAX_FRAME_BYTES + 1:
            raise DoorError("reply over frame limit")
    frame, _, rest = buffer.partition(b"\n")
    return frame, rest


class Connection:
    """One connection to one door; requests are answered in order."""

    def __init__(self, pid, timeout=10.0):
        self.pid = int(pid)
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(timeout)
        try:
            self._sock.connect(socket_path(self.pid))
        except OSError as error:
            self._sock.close()
            raise DoorError(f"cannot connect to door for pid {self.pid}: {error}") from error
        self._buffer = b""

    def request(self, cmd, args=None, request_id=None):
        request_id = request_id or str(uuid.uuid4())
        body = {"id": request_id, "cmd": cmd}
        if args is not None:
            body["args"] = args
        self._sock.sendall(json.dumps(body).encode("utf-8") + b"\n")
        frame, self._buffer = _read_frame(self._sock, self._buffer)
        try:
            reply = json.loads(frame.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise DoorError(f"reply is not JSON: {error}") from error
        if not isinstance(reply, dict):
            raise DoorError("reply is not a JSON object")
        if reply.get("door") != PROTOCOL_VERSION:
            raise DoorError(f"unsupported door version {reply.get('door')!r}")
        if reply.get("pid") != self.pid:
            raise DoorError(f"reply names pid {reply.get('pid')!r}, expected {self.pid}")
        if reply.get("id") != request_id:
            raise DoorError("reply id does not match the request")
        return reply

    def close(self):
        self._sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def request(pid, cmd, args=None, timeout=10.0):
    """Send one request on a fresh connection and return the reply object."""
    with Connection(pid, timeout=timeout) as connection:
        return connection.request(cmd, args)


def ping(pid, timeout=10.0):
    return request(pid, "ping", timeout=timeout)
