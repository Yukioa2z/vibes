#!/usr/bin/env python3
"""One-time Spotify OAuth setup using PKCE flow.

Usage:
    python3 music-spotify-setup.py <client_id>

You bring your own Spotify app — vibing-supply doesn't ship credentials.
Register a free app at https://developer.spotify.com/dashboard:

  1. "Create app" → name + description (anything)
  2. Redirect URI: http://127.0.0.1:8888/callback
     (Spotify requires the loopback IP, NOT `localhost`, for new apps)
  3. APIs used: check "Web API"
  4. Save → copy the "Client ID" → pass it to this script

Tokens land at ~/.config/music/spotify.json (gitignored). Free accounts
get read-only features (Liked detection, recently-played sync, top
tracks/artists). Premium adds playback control (play/pause/skip/save/etc.)
"""

import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import time
import urllib.parse
import urllib.request
import webbrowser

REDIRECT_PORT = 8888
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}/callback"
# Scopes:
#   user-read-currently-playing / user-read-playback-state — observe.
#   user-modify-playback-state — control (play/pause/skip/seek/volume/queue);
#     requires Spotify Premium per Spotify's API rules.
#   user-read-private — read account product field (Premium vs Free) so the
#     skill can fail fast with a clear message instead of a 403 mid-call.
#   user-read-recently-played / user-top-read — taste signal for any future
#     DJ-style recommendation logic layered on top.
SCOPES = " ".join([
    "user-read-currently-playing",
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-private",
    "user-read-recently-played",
    "user-top-read",
    "user-library-modify",
    "user-library-read",
])
CONFIG_DIR = os.path.expanduser("~/.config/music")
CONFIG_PATH = os.path.join(CONFIG_DIR, "spotify.json")


def generate_pkce():
    verifier = secrets.token_urlsafe(64)[:128]
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, challenge


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0 if len(sys.argv) >= 2 else 2)

    client_id = sys.argv[1].strip()
    if not client_id or len(client_id) < 16:
        print("error: client_id looks invalid", file=sys.stderr)
        sys.exit(2)

    verifier, challenge = generate_pkce()

    auth_url = (
        "https://accounts.spotify.com/authorize?"
        + urllib.parse.urlencode({
            "client_id": client_id,
            "response_type": "code",
            "redirect_uri": REDIRECT_URI,
            "scope": SCOPES,
            "code_challenge_method": "S256",
            "code_challenge": challenge,
        })
    )

    auth_code = None

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            nonlocal auth_code
            query = urllib.parse.urlparse(self.path).query
            params = urllib.parse.parse_qs(query)
            auth_code = params.get("code", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(
                b"<html><body style='font-family:system-ui;text-align:center;"
                b"padding:80px'><h1>Connected!</h1>"
                b"<p>You can close this tab.</p></body></html>"
            )

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("localhost", REDIRECT_PORT), Handler)

    print("Opening browser for Spotify authorization...")
    webbrowser.open(auth_url)

    server.handle_request()
    server.server_close()

    if not auth_code:
        print("Authorization failed — no code received.")
        sys.exit(1)

    # Exchange code for tokens
    data = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": auth_code,
        "redirect_uri": REDIRECT_URI,
        "client_id": client_id,
        "code_verifier": verifier,
    }).encode()

    req = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    with urllib.request.urlopen(req, timeout=10) as resp:
        tokens = json.loads(resp.read())

    os.makedirs(CONFIG_DIR, exist_ok=True)
    config = {
        "client_id": client_id,
        "access_token": tokens["access_token"],
        "refresh_token": tokens["refresh_token"],
        "expires_at": int(time.time()) + tokens.get("expires_in", 3600),
    }
    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)

    print(f"Spotify connected! Tokens saved to {CONFIG_PATH}")


if __name__ == "__main__":
    main()
