
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
        body = r"""<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Server Germany</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    min-height: 100vh;
    display: grid;
    place-items: center;
    background: radial-gradient(circle at 30% 20%, #1e293b, #0b1220 70%);
    font-family: 'Segoe UI', Tahoma, sans-serif;
    overflow: hidden;
  }

  /* هاله‌ی نور پس‌زمینه */
  body::before {
    content: "";
    position: fixed;
    width: 500px; height: 500px;
    background: radial-gradient(circle, rgba(255, 206, 0, .18), transparent 65%);
    filter: blur(40px);
    animation: float 8s ease-in-out infinite;
  }
  body::after {
    content: "";
    position: fixed;
    width: 500px; height: 500px;
    background: radial-gradient(circle, rgba(221, 0, 0, .18), transparent 65%);
    filter: blur(40px);
    animation: float 8s ease-in-out infinite reverse;
  }

  @keyframes float {
    0%, 100% { transform: translate(-200px, -150px); }
    50%      { transform: translate(200px, 150px); }
  }

  .card {
    position: relative;
    z-index: 1;
    display: flex;
    align-items: center;
    gap: 18px;
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
    to   { opacity: 1; transform: translateY(0)    scale(1); }
  }

  .flag {
    font-size: 42px;
    line-height: 1;
    filter: drop-shadow(0 4px 10px rgba(255, 206, 0, .35));
    animation: wave 3s ease-in-out infinite;
    transform-origin: bottom center;
  }

  @keyframes wave {
    0%, 100% { transform: rotate(-4deg); }
    50%      { transform: rotate(4deg);  }
  }

  .info {
    display: flex;
    flex-direction: column;
    gap: 4px;
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
    width: 10px; height: 10px;
    border-radius: 50%;
    background: #22c55e;
    box-shadow: 0 0 0 0 rgba(34, 197, 94, .7);
    animation: pulse 2s infinite;
    margin-inline-start: auto;
  }

  @keyframes pulse {
    0%   { box-shadow: 0 0 0 0 rgba(34, 197, 94, .7); }
    70%  { box-shadow: 0 0 0 14px rgba(34, 197, 94, 0); }
    100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); }
  }
</style>
</head>
<body>
  <div class="card">
    <div class="flag">🇩🇪</div>
    <div class="info">
      <span class="label">Server Location</span>
      <span class="server">Server <span class="de">Germany</span></span>
    </div>
    <div class="status" title="Online"></div>
  </div>
</body>
</html>
""".encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        if self.command != "HEAD":
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
