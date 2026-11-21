#!/usr/bin/env python3
"""Fake edge used only to test smoke.sh offline (no cluster needed).

Usage: stub_edge.py <good|leaky> <cert.pem> <key.pem> <ports-file>

`good`  behaves like the designed edge (see docs/edge.md).
`leaky` has the defects smoke.sh must catch: no HTTP->HTTPS redirect, /internal reaches auth,
        clinical's legacy register endpoint answers, Orthanc /studies is public, no rate limits.
"""
import json
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode, cert, key, ports_file = sys.argv[1:5]
lock = threading.Lock()
hits = {"volview": 0, "login": 0}
VOLVIEW_BURST, LOGIN_BURST = 100, 10


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, code, body=b"", ctype="text/html", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def json(self, code, obj):
        self.reply(code, json.dumps(obj).encode(), "application/json")

    def count(self, key, burst):
        with lock:
            hits[key] += 1
            return hits[key] > burst and mode == "good"

    def route(self):
        path = self.path.split("?")[0]
        if self.headers.get("Content-Length"):
            self.rfile.read(int(self.headers["Content-Length"]))
        leaky = mode == "leaky"
        if path.startswith("/volview/"):
            if self.command != "GET":
                return self.reply(404, b"<h1>404</h1>")
            if self.count("volview", VOLVIEW_BURST):
                return self.reply(429, b"Too Many Requests", "text/plain")
            return self.reply(200, b"<html>VolView</html>")
        if path == "/api/auth/login" and self.command == "POST":
            if self.count("login", LOGIN_BURST):
                return self.reply(429, b"Too Many Requests", "text/plain")
            return self.json(401, {"message": "Invalid credentials"})
        if path == "/api/auth/register/organization":
            return self.json(400, {"message": "legacy"}) if leaky else self.json(404, {"message": "Not Found"})
        if path in ("/internal/accounts", "/api/auth/internal/accounts"):
            return self.json(401, {"message": "bad token"}) if leaky else self.reply(404, b"<h1>404</h1>")
        if path.startswith("/imaging/studies/") and path.endswith("/derived/lung-surface") and self.command == "GET":
            return self.json(404, {"detail": "Study not found"})
        if path in ("/studies", "/app/explorer.html") and leaky:
            return self.json(200, ["study-1"])
        return self.reply(404, b"<h1>404</h1>")

    do_GET = do_POST = do_PUT = do_DELETE = route


class Redirect(Handler):
    def route(self):
        if mode == "leaky":
            return self.reply(200, b"plain http app")
        self.reply(308, b"", extra={"Location": "https://" + (self.headers.get("Host") or "x") + self.path})

    do_GET = do_POST = do_PUT = do_DELETE = route


class Quiet(ThreadingHTTPServer):
    def handle_error(self, request, client_address):  # failed TLS handshakes are expected in some tests
        pass


http = Quiet(("127.0.0.1", 0), Redirect)
https = Quiet(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
https.socket = ctx.wrap_socket(https.socket, server_side=True)
with open(ports_file, "w") as fh:
    fh.write(f"{http.server_address[1]} {https.server_address[1]}\n")
threading.Thread(target=http.serve_forever, daemon=True).start()
https.serve_forever()
