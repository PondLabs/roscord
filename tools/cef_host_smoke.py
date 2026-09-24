#!/usr/bin/env python3
"""Smoke-test a bundled CEF host by acting as the app.

Starts the bundle's CEF host, speaks the BrowserRuntime wire protocol to it,
opens one embedded surface, and reads the frames the host publishes in its
shared-memory ring.  It passes when frames arrive, the newest one is not
blank, and the host exits once its parent disconnects; `--png` also writes
that frame to disk.

Linux: `<bundle>/cef_host`, a Unix socket, and POSIX shared memory.
Windows: `<bundle>/cef_host/cef_host.exe`, a named pipe, and a file mapping.

    python3 tools/cef_host_smoke.py --bundle commet/build/linux/x64/release/bundle
    python3 tools/cef_host_smoke.py --bundle <dir> --youtube aqz-KE-bpKQ --seconds 20 --png /tmp/frame.png

The frame ring layout is browser_surface/native/browser_frame_ring.h.
"""

from __future__ import annotations

import argparse
import http.server
import json
import mmap
import os
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = 1
RING_MAGIC = 0x52464352
RING_HEADER_BYTES = 4096
RING_SLOT_OFFSET = 64
RING_SLOT_BYTES = 64
WINDOWS = sys.platform == "win32"

FIXTURE_HTML = b"""<!DOCTYPE html>
<html><body style="margin:0;background:#1e6fd9;color:#fff;font:48px sans-serif">
<div style="padding:40px">roscord cef_host smoke test</div>
</body></html>"""

YOUTUBE_WRAPPER = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>
html, body {{ margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }}
iframe {{ position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }}
</style>
</head>
<body>
<iframe src="https://www.youtube-nocookie.com/embed/{video}?autoplay=1&amp;mute=1&amp;enablejsapi=1&amp;playsinline=1&amp;rel=0&amp;controls=1&amp;fs=1"
  allow="autoplay; encrypted-media; fullscreen; picture-in-picture"
  allowfullscreen
  referrerpolicy="strict-origin-when-cross-origin"></iframe>
</body>
</html>"""


class UnixTransport:
    """The Linux host's owner-only Unix socket."""

    def __init__(self, path: Path) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(path))
        self.sock.settimeout(0.05)
        self.buffer = bytearray()

    def write(self, data: bytes) -> None:
        self.sock.settimeout(None)
        self.sock.sendall(data)
        self.sock.settimeout(0.05)

    def read_available(self) -> bool:
        """Reads what has arrived.  Returns False once the host hung up."""
        try:
            chunk = self.sock.recv(65536)
        except socket.timeout:
            return True
        if not chunk:
            return False
        self.buffer.extend(chunk)
        return True

    def close(self) -> None:
        self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()


class PipeTransport:
    """The Windows host's private named pipe.

    Reads only what PeekNamedPipe says has arrived, so no read is ever
    pending while the harness writes: synchronous pipe handles serialize the
    two.
    """

    def __init__(self, path: str) -> None:
        import ctypes
        import msvcrt
        from ctypes import wintypes

        self.file = open(path, "r+b", buffering=0)  # noqa: SIM115 (closed in close())
        self.handle = msvcrt.get_osfhandle(self.file.fileno())
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.peek = kernel32.PeekNamedPipe
        self.peek.argtypes = [
            wintypes.HANDLE,
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.c_void_p,
            ctypes.POINTER(wintypes.DWORD),
            ctypes.c_void_p,
        ]
        self.peek.restype = wintypes.BOOL
        self.dword = wintypes.DWORD
        self.byref = ctypes.byref
        self.buffer = bytearray()

    def write(self, data: bytes) -> None:
        self.file.write(data)

    def read_available(self) -> bool:
        available = self.dword(0)
        if not self.peek(self.handle, None, 0, None, self.byref(available), None):
            return False
        if available.value:
            self.buffer.extend(self.file.read(available.value))
        else:
            time.sleep(0.02)
        return True

    def close(self) -> None:
        self.file.close()


class Wire:
    """Length-prefixed JSON frames authenticated by the parent nonce."""

    def __init__(self, transport: UnixTransport | PipeTransport, nonce: str) -> None:
        self.transport = transport
        self.nonce = nonce
        self.open = True

    def send(self, message: dict[str, Any]) -> None:
        body = json.dumps(
            {"version": PROTOCOL_VERSION, "nonce": self.nonce, "message": message}
        ).encode()
        self.transport.write(struct.pack(">I", len(body)) + body)

    def poll(self) -> list[dict[str, Any]]:
        """Every complete message received so far."""
        if self.open and not self.transport.read_available():
            self.open = False
        messages = []
        buffer = self.transport.buffer
        while len(buffer) >= 4:
            (size,) = struct.unpack(">I", buffer[:4])
            if len(buffer) < 4 + size:
                break
            envelope = json.loads(bytes(buffer[4 : 4 + size]))
            del buffer[: 4 + size]
            if envelope.get("nonce") != self.nonce or envelope.get("version") != PROTOCOL_VERSION:
                raise RuntimeError("host frame failed authentication")
            messages.append(envelope["message"])
        return messages


def _open_ring(buffer: str):
    if WINDOWS:
        header = mmap.mmap(-1, RING_HEADER_BYTES, tagname=buffer, access=mmap.ACCESS_READ)
        _, _, slot_count, _, slot_bytes = struct.unpack_from("<IIIIQ", header, 0)
        header.close()
        size = RING_HEADER_BYTES + slot_count * slot_bytes
        return mmap.mmap(-1, size, tagname=buffer, access=mmap.ACCESS_READ)
    path = Path("/dev/shm") / buffer.lstrip("/")
    with open(path, "rb") as handle:
        return mmap.mmap(handle.fileno(), 0, prot=mmap.PROT_READ)


def read_frame(buffer: str, slot: int, sequence: int) -> tuple[int, int, bytes] | None:
    """Reads one RGBA frame from the host's ring, or None if it was replaced."""

    with _open_ring(buffer) as region:
        magic, version, slot_count, _, slot_bytes = struct.unpack_from("<IIIIQ", region, 0)
        if magic != RING_MAGIC or version != 1 or slot >= slot_count:
            raise RuntimeError("frame ring header is invalid")
        slot_header = RING_SLOT_OFFSET + slot * RING_SLOT_BYTES
        _, end, width, height = struct.unpack_from("<QQII", region, slot_header)
        if end != sequence:
            return None
        start = RING_HEADER_BYTES + slot * slot_bytes
        pixels = bytes(region[start : start + width * height * 4])
        (begin_after,) = struct.unpack_from("<Q", region, slot_header)
        if begin_after != sequence:
            return None
        return width, height, pixels


def serve(html: bytes) -> tuple[http.server.HTTPServer, int]:
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 (http.server API)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(html)

        def log_message(self, *args: Any) -> None:
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def _launch(bundle: Path, nonce: str, work: Path, software: bool):
    """Starts the host and returns (process, endpoint)."""

    if WINDOWS:
        host = bundle / "cef_host" / "cef_host.exe"
        endpoint = rf"\\.\pipe\roscord-browser-{os.getpid()}-{nonce}"
        command = [
            str(host),
            f"--pipe={endpoint}",
            f"--nonce={nonce}",
            f"--parent-pid={os.getpid()}",
            f"--profile-root={work / 'profiles'}",
        ]
    else:
        host = bundle / "cef_host"
        runtime_parent = Path(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir())
        socket_dir = Path(tempfile.mkdtemp(prefix="roscord-browser-smoke-", dir=runtime_parent))
        endpoint = str(socket_dir / "host.sock")
        command = [
            str(host),
            f"--socket={endpoint}",
            f"--parent-pid={os.getpid()}",
            f"--parent-nonce={nonce}",
            f"--cef-root={bundle / 'cef'}",
            f"--profile-root={work / 'profiles'}",
        ]
    if software:
        command.append("--cef-software-rendering")
    process = subprocess.Popen(
        command,
        cwd=host.parent,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    return process, endpoint


def _connect(endpoint: str, process: subprocess.Popen) -> UnixTransport | PipeTransport | None:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and process.poll() is None:
        try:
            return PipeTransport(endpoint) if WINDOWS else UnixTransport(Path(endpoint))
        except OSError:
            time.sleep(0.1)
    return None


def write_png(path: Path, width: int, height: int, rgba: bytes) -> None:
    """Writes 8-bit RGBA pixels as a PNG, with no image library."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    stride = width * 4
    rows = b"".join(b"\0" + rgba[y * stride : (y + 1) * stride] for y in range(height))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 6))
        + chunk(b"IEND", b"")
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bundle", required=True, type=Path, help="the built app bundle")
    parser.add_argument("--youtube", metavar="VIDEO_ID", help="open the app's YouTube wrapper for VIDEO_ID")
    parser.add_argument("--url", help="open this URL instead of the local fixture page")
    parser.add_argument("--seconds", type=float, default=8.0, help="how long to collect frames")
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=540)
    parser.add_argument("--png", type=Path, help="write the newest frame here")
    parser.add_argument("--click", nargs=2, type=float, metavar=("X", "Y"), help="click here after the first frame")
    parser.add_argument("--hover", nargs=2, type=float, metavar=("X", "Y"), help="move the pointer here after the first frame")
    parser.add_argument("--software", action="store_true", help="pass --cef-software-rendering")
    parser.add_argument("--verbose", action="store_true", help="print every host message but frames")
    args = parser.parse_args(argv)

    bundle = args.bundle.resolve()
    work = Path(tempfile.mkdtemp(prefix="roscord-cef-smoke-"))
    nonce = secrets.token_hex(16)

    loopback_origins: list[str] = []
    allowed_origins: list[str] = []
    if args.youtube:
        _, port = serve(YOUTUBE_WRAPPER.format(video=args.youtube).encode())
        url = f"http://127.0.0.1:{port}/embed"
        loopback_origins = [f"http://127.0.0.1:{port}"]
        allowed_origins = [
            "https://m.youtube.com",
            "https://www.youtube-nocookie.com",
            "https://www.youtube.com",
            "https://youtube.com",
        ]
    elif args.url:
        url = args.url
        allowed_origins = ["/".join(url.split("/")[:3])]
    else:
        _, port = serve(FIXTURE_HTML)
        url = f"http://127.0.0.1:{port}/"
        loopback_origins = [f"http://127.0.0.1:{port}"]

    process, endpoint = _launch(bundle, nonce, work, args.software)
    stderr_lines: list[str] = []
    threading.Thread(
        target=lambda: stderr_lines.extend(process.stderr), daemon=True  # type: ignore[arg-type]
    ).start()

    def fail(message: str) -> int:
        if process.poll() is None:
            process.kill()
        print(message, file=sys.stderr)
        print("".join(stderr_lines), file=sys.stderr)
        return 1

    transport = _connect(endpoint, process)
    if transport is None:
        return fail("the CEF host did not open its endpoint")
    wire = Wire(transport, nonce)
    wire.send(
        {
            "type": "open",
            "payload": {
                "request_id": 1,
                "spec": {
                    "profile_key": "official-video",
                    "presentation": "embedded",
                    "privacy": "persistent",
                    "initial_navigation": {"url": url, "disposition": "current", "user_initiated": False},
                    "policy": {
                        "allowed_origins": allowed_origins,
                        "allowed_loopback_origins": loopback_origins,
                        "allow_external_navigation": True,
                        "capabilities": {},
                    },
                },
            },
        }
    )

    state: dict[str, Any] = {"surface": None, "ready": False, "closed": False, "latest": None}
    frame_count = 0
    events: list[str] = []
    counters = {"request": 2, "sequence": 1}

    def command(kind: str, payload: dict[str, Any]) -> None:
        payload = dict(payload, sequence=counters["sequence"], profile_key="official-video")
        counters["sequence"] += 1
        request = counters["request"]
        counters["request"] += 1
        wire.send(
            {
                "type": "command",
                "payload": {
                    "request_id": request,
                    "surface_id": state["surface"],
                    "command": {"type": kind, "payload": payload},
                },
            }
        )

    def pump() -> None:
        nonlocal frame_count
        for message in wire.poll():
            kind = message["type"]
            payload = message["payload"]
            if kind == "opened":
                state["surface"] = payload["surface_id"]
            elif kind == "event":
                event = payload["event"]
                event_type = event["type"]
                if event_type == "frame_ready":
                    frame_count += 1
                    state["latest"] = event["payload"]["frame"]
                    continue
                events.append(event_type)
                if args.verbose:
                    print("event", json.dumps(event), flush=True)
                if event_type == "ready":
                    state["ready"] = True
                elif event_type == "closed":
                    state["closed"] = True
            elif kind == "error":
                print("host error", json.dumps(payload), flush=True)

    deadline = time.monotonic() + 30
    while not state["ready"] and time.monotonic() < deadline and wire.open:
        pump()
    if not state["ready"]:
        return fail("the surface never became ready")
    command("resize", {"width": args.width, "height": args.height, "device_scale_factor": 1.0})
    command("focus", {"focused": True})

    started = time.monotonic()
    clicked = False
    while time.monotonic() - started < args.seconds and wire.open:
        pump()
        if (args.click or args.hover) and state["latest"] and not clicked:
            # Let the page settle before interacting.
            if time.monotonic() - started < args.seconds / 2:
                continue
        if (args.click or args.hover) and state["latest"] and not clicked:
            x, y = args.click or args.hover
            steps = (("move", 0), ("down", 1), ("up", 1)) if args.click else (("move", 0),)
            for kind, buttons in steps:
                pointer = {"kind": kind, "x": x, "y": y, "buttons": buttons, "delta_x": 0, "delta_y": 0}
                command("input", {"input": {"type": "pointer", "payload": pointer}})
            clicked = True

    result = 0
    latest = state["latest"]
    if not latest:
        print("no frames arrived", file=sys.stderr)
        result = 1
    else:
        frame = None
        for _ in range(20):
            frame = read_frame(latest["buffer"], latest["slot"], latest["sequence"])
            if frame:
                break
            time.sleep(0.05)
        if frame is None:
            print("the newest frame was replaced while reading it", file=sys.stderr)
            result = 1
        else:
            width, height, pixels = frame
            distinct = len({pixels[i : i + 4] for i in range(0, len(pixels), 4 * 97)})
            print(f"frames={frame_count} newest={width}x{height} seq={latest['sequence']} distinct_colours~{distinct}")
            if distinct < 2:
                print("the newest frame is blank", file=sys.stderr)
                result = 1
            if args.png:
                write_png(args.png, width, height, pixels)
    print("events:", " ".join(dict.fromkeys(events)))

    wire.send({"type": "close", "payload": {"surface_id": state["surface"]}})
    deadline = time.monotonic() + 10
    while not state["closed"] and time.monotonic() < deadline and wire.open:
        pump()
    if not state["closed"]:
        print("the surface did not report closed", file=sys.stderr)
        result = 1
    transport.close()
    try:
        process.wait(20)
    except subprocess.TimeoutExpired:
        process.kill()
        print("the CEF host did not exit after its parent disconnected", file=sys.stderr)
        result = 1
    print(f"cef_host exit code: {process.returncode}")
    if process.returncode not in (0, None) and result == 0:
        print(f"the CEF host exited with {process.returncode}", file=sys.stderr)
        result = 1
    if result != 0 or args.verbose:
        print("".join(stderr_lines), file=sys.stderr)
    return result


if __name__ == "__main__":
    sys.exit(main())
