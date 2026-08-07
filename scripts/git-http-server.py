#!/usr/bin/env python3
"""Minimal git HTTP server for local mirrors.

Serves bare git repositories under GIT_PROJECT_ROOT over HTTP by delegating
every request to `git http-backend` (the same backend Apache/nginx use), so
both the smart HTTP protocol (v0 and v2) and the dumb static protocol work
for any git client - including Zig's package manager fetching a
`git+http://` dependency from a local mirror.

Usage: GIT_PROJECT_ROOT=/path/to/repos git-http-server.py [port]
"""

import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

GIT_PROJECT_ROOT = os.environ.get("GIT_PROJECT_ROOT") or os.getcwd()
DEFAULT_PORT = 8765


class GitHTTPHandler(BaseHTTPRequestHandler):
    server_version = "git-http-server/1.0"
    # Git's smart HTTP client requires HTTP/1.1 (keep-alive, content-length).
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("git-http-server: %s\n" % (fmt % args))

    def _dispatch(self, payload=b""):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            # Liveness probe (curl to /); a 404 still proves the socket works.
            self.send_response(404)
            self.end_headers()
            return
        env = os.environ.copy()
        env.update(
            {
                "GIT_PROJECT_ROOT": GIT_PROJECT_ROOT,
                "GIT_HTTP_EXPORT_ALL": "1",
                "PATH_INFO": parsed.path,
                "QUERY_STRING": parsed.query,
                "REQUEST_METHOD": self.command,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(len(payload)),
                "HTTP_GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
                "REMOTE_ADDR": self.client_address[0],
                "SERVER_PROTOCOL": self.request_version,
                "SERVER_NAME": self.server.server_address[0],
                "SERVER_PORT": str(self.server.server_address[1]),
            }
        )
        proc = subprocess.run(
            ["git", "http-backend"], input=payload, capture_output=True, env=env
        )
        if proc.stderr:
            sys.stderr.write(
                "git-http-server: http-backend stderr: %s\n"
                % proc.stderr.decode(errors="replace").strip()
            )
        header_blob, _, body = proc.stdout.partition(b"\r\n\r\n")
        status = 200
        headers = []
        for line in header_blob.split(b"\r\n"):
            if b":" not in line:
                continue
            key, _, value = line.partition(b":")
            key = key.decode().strip().lower()
            value = value.decode().strip()
            if key == "status":
                try:
                    status = int(value.split()[0])
                except ValueError:
                    status = 500
            elif key in ("content-type", "content-length", "cache-control"):
                headers.append((key, value))
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._dispatch()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(length) if length else b""
        self._dispatch(payload)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    server = ThreadingHTTPServer(("127.0.0.1", port), GitHTTPHandler)
    print("listening on %d" % port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
