#!/usr/bin/env python3
"""Fast HTTP proxy for opencode on Android.
Bun's io_uring networking doesn't work on Android, so we route
API requests through this Python proxy on localhost.
"""
import http.server
import urllib.request
import ssl
import sys
import os
import socket

TARGET = os.environ.get("PROXY_TARGET", "https://opencode.ai")
PORT = int(os.environ.get("PROXY_PORT", "8080"))

# Reuse a single SSL context and opener
ctx = ssl.create_default_context()
opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_request(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length else None

        url = TARGET + self.path
        req = urllib.request.Request(url, data=body, method=self.command)
        for key, val in self.headers.items():
            if key.lower() not in ('host', 'proxy-connection', 'accept-encoding'):
                req.add_header(key, val)

        try:
            resp = opener.open(req, timeout=120)
            self.send_response(resp.status)
            for key, val in resp.getheaders():
                if key.lower() not in ('transfer-encoding',):
                    self.send_header(key, val)
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
                if key.lower() not in ('transfer-encoding',):
                    self.send_header(key, val)
            self.end_headers()
            if e.readable():
                self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())

    do_POST = do_request
    do_PUT = do_request
    do_PATCH = do_request
    do_DELETE = do_request

    def do_GET(self):
        self.do_request()

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', '*')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.end_headers()

    def log_message(self, format, *args):
        pass

if __name__ == '__main__':
    sys.stdout = open(os.devnull, 'w')
    sys.stderr = open(os.devnull, 'w')
    server = http.server.HTTPServer(('127.0.0.1', PORT), ProxyHandler)
    server.serve_forever()
