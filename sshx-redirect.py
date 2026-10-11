#!/usr/bin/env python3
"""Small dependency-free HTTP server for the Germany server status page."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socket import SHUT_RDWR
from typing import Optional

HTML = r"""<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="dark">
<title>Server Germany</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    min-height: 100vh;
    min-height: 100svh;
    display: grid;
    place-items: center;
    padding: 16px;
    background: radial-gradient(circle at 30% 20%, #1e293b, #0b1220 70%);
    font-family: 'Segoe UI', Tahoma, sans-serif;
    overflow-x: hidden;
    overflow-y: auto;
  }

  body::before,
  body::after {
    content: "";
    position: fixed;
    top: 50%;
    left: 50%;
    width: 500px;
    height: 500px;
    pointer-events: none;
    filter: blur(40px);
  }

  body::before {
    background: radial-gradient(circle, rgba(255, 206, 0, .18), transparent 65%);
    animation: float 8s ease-in-out infinite;
  }

  body::after {
    background: radial-gradient(circle, rgba(221, 0, 0, .18), transparent 65%);
    animation: float 8s ease-in-out infinite reverse;
  }

  @keyframes float {
    0%, 100% { transform: translate(-200px, -150px); }
    50% { transform: translate(200px, 150px); }
  }

  .card {
    position: relative;
    z-index: 1;
    display: flex;
    align-items: center;
    gap: 18px;
    width: max-content;
    max-width: 100%;
    padding: 22px 34px;
    border-radius: 20px;
    background: rgba(255, 255, 255, .04);
    border: 1px solid rgba(255, 255, 255, .12);
    backdrop-filter: blur(14px);
    -webkit-backdrop-filter: blur(14px);
    box-shadow:
      0 20px 60px rgba(0, 0, 0, .55),
      inset 0 1px 0 rgba(255, 255, 255, .08);
    animation: rise .8s cubic-bezier(.2, .8, .2, 1) both;
  }

  @keyframes rise {
    from { opacity: 0; transform: translateY(20px) scale(.96); }
    to { opacity: 1; transform: translateY(0) scale(1); }
  }

  .flag {
    flex-shrink: 0;
    font-size: 42px;
    line-height: 1;
    filter: drop-shadow(0 4px 10px rgba(255, 206, 0, .35));
    animation: wave 3s ease-in-out infinite;
    transform-origin: bottom center;
  }

  @keyframes wave {
    0%, 100% { transform: rotate(-4deg); }
    50% { transform: rotate(4deg); }
  }

  .info {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
  }

  .label {
    font-size: 12px;
    letter-spacing: 3px;
    text-transform: uppercase;
    color: #94a3b8;
  }

  .server {
    font-size: 26px;
    font-weight: 700;
    color: #fff;
    letter-spacing: .5px;
    white-space: nowrap;
    background: linear-gradient(90deg, #fff, #cbd5e1);
    -webkit-background-clip: text;
    background-clip: text;
    -webkit-text-fill-color: transparent;
  }

  .server .de {
    background: linear-gradient(90deg, #ffce00, #dd0000);
    -webkit-background-clip: text;
    background-clip: text;
    -webkit-text-fill-color: transparent;
  }

  .status {
    width: 10px;
    height: 10px;
    flex-shrink: 0;
    border-radius: 50%;
    background: #22c55e;
    box-shadow: 0 0 0 0 rgba(34, 197, 94, .7);
    animation: pulse 2s infinite;
    margin-inline-start: auto;
  }

  @keyframes pulse {
    0% { box-shadow: 0 0 0 0 rgba(34, 197, 94, .7); }
    70% { box-shadow: 0 0 0 14px rgba(34, 197, 94, 0); }
    100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); }
  }

  @media (max-width: 420px) {
    .card { gap: 12px; padding: 18px 16px; }
    .server { font-size: clamp(18px, 6vw, 22px); }
    .label { letter-spacing: 2px; }
    .flag { font-size: 34px; }
  }

  @media (max-width: 320px) {
    .card { gap: 9px; padding-inline: 12px; }
    .label { font-size: 10px; letter-spacing: 1.5px; }
    .server { font-size: 18px; }
    .flag { font-size: 30px; }
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      animation-duration: 0.01ms !important;
      animation-iteration-count: 1 !important;
      scroll-behavior: auto !important;
    }
  }
</style>
</head>
<body>
  <main class="card" aria-label="Germany server status">
    <div class="flag" role="img" aria-label="پرچم آلمان">🇩🇪</div>
    <div class="info">
      <span class="label">Server Location</span>
      <span class="server">Server <span class="de">Germany</span></span>
    </div>
    <span class="status" role="img" aria-label="Online" title="Online"></span>
  </main>
</body>
</html>
"""

PAGE_BYTES = HTML.encode("utf-8")


class GermanyHTTPServer(ThreadingHTTPServer):
    """Threaded server configured for a small standalone status page."""

    daemon_threads = True
    allow_reuse_address = True


class WebHandler(BaseHTTPRequestHandler):
    server_version = "GermanyWebServer/1.1"
    sys_version = ""

    def version_string(self) -> str:
        # Avoid exposing the Python version in the Server response header.
        return self.server_version

    def _send_page_headers(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE_BYTES)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        )
        self.send_header(
            "Permissions-Policy",
            "camera=(), microphone=(), geolocation=()",
        )
        self.end_headers()

    def do_GET(self) -> None:
        self._send_page_headers()
        try:
            self.wfile.write(PAGE_BYTES)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            # A browser/client may disconnect before receiving the complete page.
            # Do not let that normal network condition crash the request thread.
            pass

    def do_HEAD(self) -> None:
        self._send_page_headers()

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Allow", "GET, HEAD, OPTIONS")
        # A 204 No Content response must not include Content-Length.
        self.end_headers()

    def _method_not_allowed(self) -> None:
        body = b"Method Not Allowed\n"
        self.send_response(405)
        self.send_header("Allow", "GET, HEAD, OPTIONS")
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            pass

    do_POST = _method_not_allowed
    do_PUT = _method_not_allowed
    do_PATCH = _method_not_allowed
    do_DELETE = _method_not_allowed

    def log_message(self, fmt: str, *args: object) -> None:
        print("[http] " + (fmt % args), flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Germany Server HTML Web Server")
    parser.add_argument("--host", default="0.0.0.0", help="Interface to bind (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8080, help="TCP port to listen on (default: 8080)")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    return args


def main() -> None:
    args = parse_args()
    try:
        server = GermanyHTTPServer((args.host, args.port), WebHandler)
    except OSError as exc:
        raise SystemExit(f"[http] Could not bind to {args.host}:{args.port}: {exc}") from exc

    print(f"[http] Server running at http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        print("\n[http] Shutting down...", flush=True)
    finally:
        server.server_close()
        print("[http] Server stopped.", flush=True)


if __name__ == "__main__":
    main()
