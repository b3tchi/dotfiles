#!/usr/bin/env python3
"""Relay a Debian mirror to the cable so the installer needs no NAT/DNS.

Run on the cable host (no root):  python3 mirror-proxy.py 10.42.0.1 8080
Installer mirror: hostname 10.42.0.1:8080, directory /debian.
Plain HTTP only: apt verifies everything against the signed Release files.
"""
import shutil
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "http://deb.debian.org"


class Relay(BaseHTTPRequestHandler):
    def _relay(self, body):
        req = urllib.request.Request(UPSTREAM + self.path, method=self.command)
        try:
            up = urllib.request.urlopen(req, timeout=60)
        except urllib.error.HTTPError as e:
            up = e
        with up:
            self.send_response(up.status)
            for k in ("Content-Type", "Content-Length", "Last-Modified", "ETag"):
                if up.headers.get(k):
                    self.send_header(k, up.headers[k])
            self.end_headers()
            if body:
                shutil.copyfileobj(up, self.wfile, 1 << 16)

    def do_GET(self):
        self._relay(True)

    def do_HEAD(self):
        self._relay(False)


if __name__ == "__main__":
    host, port = sys.argv[1], int(sys.argv[2])
    ThreadingHTTPServer((host, port), Relay).serve_forever()
