#!/usr/bin/env python3
"""Small local HTTP front end for the dynamically discovered SSHX URL."""
import argparse
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VALID_URL = re.compile(r"^https://sshx\.io/s/[A-Za-z0-9_-]+#[A-Za-z0-9_-]+$")


def read_url(path):
    try:
        with open(path, encoding="ascii") as stream:
            value = stream.read().strip()
    except (FileNotFoundError, OSError, UnicodeError):
        return None
    return value if VALID_URL.fullmatch(value) else None


class RedirectHandler(BaseHTTPRequestHandler):
    server_version = "sshx-redirect/1.0"

    def do_GET(self):
        url = read_url(self.server.url_file)
        if url:
            self.send_response(302)
            self.send_header("Location", url)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return

        body = (
            "<!doctype html><meta charset=utf-8><title>Starting SSHX</title>"
            "<meta http-equiv=refresh content=5>"
            "<h1>SSHX is starting</h1><p>This page will refresh automatically.</p>"
        ).encode()
        self.send_response(503)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Retry-After", "5")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, format, *args):
        print("[http] " + (format % args), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--url-file", required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), RedirectHandler)
    server.url_file = os.path.abspath(args.url_file)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
