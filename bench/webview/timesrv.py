#!/usr/bin/env python3
# Timestamping static server for the webview benchmark.
# Serves DOCROOT; stamps the wall-clock of the first document GET (MARKER) and of
# the /__done render beacon (MARKER.done), so a launcher can measure
# launch->first-GET and launch->rendered.
#   usage: timesrv.py DOCROOT PORT MARKER
import http.server, socketserver, time, sys, os

DOCROOT = sys.argv[1] if len(sys.argv) > 1 else "."
PORT    = int(sys.argv[2]) if len(sys.argv) > 2 else 4899
MARKER  = sys.argv[3] if len(sys.argv) > 3 else "/tmp/wvbench/first.txt"
os.chdir(DOCROOT)

class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        p = self.path.split("?")[0]
        if p in ("/", "/index.html", "/graph.html", "/image.html") and not os.path.exists(MARKER):
            open(MARKER, "w").write(repr(time.time()))
        if p == "/__done":
            open(MARKER + ".done", "w").write(repr(time.time()))
            self.send_response(204); self.end_headers(); return
        return super().do_GET()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), H) as s:
    s.serve_forever()
