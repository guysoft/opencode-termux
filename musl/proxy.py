#!/usr/bin/env python3
"""HTTP proxy for opencode on Android.

Bun's io_uring networking doesn't work on Android, so we route all
outbound HTTP/HTTPS traffic through this Python proxy on localhost.

Supports three modes:

1. Fixed-target reverse proxy (legacy):
   Set PROXY_TARGET=https://example.com and requests to the proxy are
   forwarded to https://example.com<path>. This is what opencode's
   /v1/* API hits.

2. Absolute-URL forward proxy:
   If the request line contains an absolute URL (e.g. GET http://...),
   the proxy extracts the target and forwards. This is what most
   HTTP libraries do when HTTP_PROXY is set.

3. HTTP CONNECT tunnel (for HTTPS through HTTP_PROXY):
   The client sends CONNECT host:port HTTP/1.1, the proxy opens a
   raw TCP socket to the target, and pipes bytes both ways. Used
   by HTTP libraries for HTTPS targets when HTTP_PROXY is set.
"""
import http.server
import urllib.request
import ssl
import sys
import os
import socket
import select
import threading

TARGET = os.environ.get("PROXY_TARGET", "https://opencode.ai")
PORT = int(os.environ.get("PROXY_PORT", "8080"))

ctx = ssl.create_default_context()
opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _absolute_target(self):
        """Return absolute target URL if request line is an absolute URI."""
        if self.command == "CONNECT":
            return None
        path = self.path
        if path.startswith(("http://", "https://")):
            return path
        return None

    def _forward(self, url, body):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else None
        req = urllib.request.Request(url, data=body, method=self.command)
        for key, val in self.headers.items():
            if key.lower() not in ("host", "proxy-connection", "accept-encoding"):
                req.add_header(key, val)
        try:
            resp = opener.open(req, timeout=120)
            self.send_response(resp.status)
            for key, val in resp.getheaders():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for key, val in e.headers.items():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.send_header("Connection", "close")
            self.end_headers()
            if e.readable():
                self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(str(e).encode())

    def do_request(self):
        target = self._absolute_target() or (TARGET + self.path)
        self._forward(target, None)

    def do_CONNECT(self):
        try:
            host, port = self.path.split(":", 1)
            port = int(port)
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return

        try:
            upstream = socket.create_connection((host, port), timeout=30)
        except Exception as e:
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(str(e).encode())
            return

        self.send_response(200, "Connection Established")
        self.send_header("Connection", "close")
        self.end_headers()

        sock = self.connection
        try:
            self._tunnel(sock, upstream)
        finally:
            try:
                upstream.close()
            except OSError:
                pass

    def _tunnel(self, client, upstream):
        sockets = [client, upstream]
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], 60)
                if not readable:
                    break
                for s in readable:
                    other = upstream if s is client else client
                    data = s.recv(65536)
                    if not data:
                        return
                    other.sendall(data)
        except (OSError, ConnectionResetError):
            pass
        finally:
            for s in sockets:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    do_GET = do_request
    do_POST = do_request
    do_PUT = do_request
    do_PATCH = do_request
    do_DELETE = do_request

    def do_OPTIONS(self):
        self.do_request()

    def log_message(self, format, *args):
        pass


class ThreadedHTTPServer(http.server.HTTPServer):
    """Handle each request in a thread so CONNECT tunnels don't block."""

    def process_request(self, request, client_address):
        t = threading.Thread(target=self._process_request, args=(request, client_address), daemon=True)
        t.start()

    def _process_request(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    if os.environ.get("PROXY_DEBUG"):
        log_path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "proxy.log")
        sys.stdout = open(log_path, "a")
        sys.stderr = sys.stdout
    else:
        sys.stdout = open(os.devnull, "w")
        sys.stderr = open(os.devnull, "w")
    server = ThreadedHTTPServer(("127.0.0.1", PORT), ProxyHandler)
    server.serve_forever()
