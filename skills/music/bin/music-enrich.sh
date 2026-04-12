#!/usr/bin/env bash
# music-enrich.sh — Enrich a track with genre metadata.
#
# Three tiers:
#   1. Spotify API  → artist genres (requires one-time OAuth setup)
#   2. iTunes Search API → primaryGenreName (free, no auth)
#   3. Neither → empty (graceful fallback)
#
# Usage: music-enrich.sh "Artist" "Title"
# Outputs JSON: {"genre":"Rock","genres":["indie rock","art rock"]}
#
# Called by music-poll.sh on song change. Each API call is bounded by
# --max-time so a slow/down service can't stall the poll cycle.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=music-spotify-auth.sh
source "$SCRIPT_DIR/music-spotify-auth.sh"

ARTIST="${1:-}"
TITLE="${2:-}"

[[ -z "$ARTIST" || -z "$TITLE" ]] && { echo '{}'; exit 0; }

SPOTIFY_GENRES=""
ITUNES_GENRE=""

# ── 1. Spotify (if configured) ────────────────────────────────────
spotify_enrich() {
  local access_token
  access_token="$(spotify_get_token)" || return
  [[ -z "$access_token" ]] && return

  # Search for the track → get artist ID → get artist genres
  SPOTIFY_GENRES="$(ENRICH_TOKEN="$access_token" ENRICH_ARTIST="$ARTIST" ENRICH_TITLE="$TITLE" python3 -c '
import json, os, urllib.request, urllib.parse

token = os.environ["ENRICH_TOKEN"]
artist = os.environ["ENRICH_ARTIST"]
title = os.environ["ENRICH_TITLE"]

q = urllib.parse.quote(f"artist:{artist} track:{title}")
url = f"https://api.spotify.com/v1/search?q={q}&type=track&limit=1"
req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})

try:
    with urllib.request.urlopen(req, timeout=3) as r:
        data = json.loads(r.read())
    tracks = data.get("tracks", {}).get("items", [])
    if not tracks:
        raise SystemExit(0)

    artist_id = tracks[0]["artists"][0]["id"]
    url2 = f"https://api.spotify.com/v1/artists/{artist_id}"
    req2 = urllib.request.Request(url2, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req2, timeout=3) as r2:
        artist_data = json.loads(r2.read())

    genres = artist_data.get("genres", [])
    if genres:
        print(json.dumps(genres))
except SystemExit:
    raise
except Exception:
    pass
' 2>/dev/null)" || true
}

# ── 2. iTunes Search API (universal, no auth) ─────────────────────
itunes_enrich() {
  ITUNES_GENRE="$(ENRICH_ARTIST="$ARTIST" ENRICH_TITLE="$TITLE" python3 -c '
import json, os, urllib.request, urllib.parse

artist = os.environ["ENRICH_ARTIST"]
title = os.environ["ENRICH_TITLE"]
q = urllib.parse.quote(f"{artist} {title}")
url = f"https://itunes.apple.com/search?term={q}&media=music&limit=3"

try:
    with urllib.request.urlopen(url, timeout=3) as r:
        data = json.loads(r.read())
    results = data.get("results", [])
    if not results:
        raise SystemExit(0)

    # Prefer matching artist
    al = artist.lower()
    for r in results:
        if al in r.get("artistName", "").lower():
            print(r.get("primaryGenreName", ""))
            raise SystemExit(0)
    print(results[0].get("primaryGenreName", ""))
except SystemExit:
    raise
except Exception:
    pass
' 2>/dev/null)" || true
}

# Run both (Spotify first — if it fails, iTunes still runs)
spotify_enrich
itunes_enrich

# ── Build output JSON ──────────────────────────────────────────────
python3 -c '
import json, sys

genre = sys.argv[1] if len(sys.argv) > 1 else ""
spotify_raw = sys.argv[2] if len(sys.argv) > 2 else ""

out = {}
try:
    spotify_genres = json.loads(spotify_raw) if spotify_raw else []
except Exception:
    spotify_genres = []

if spotify_genres:
    out["genres"] = spotify_genres
if genre:
    out["genre"] = genre
print(json.dumps(out))
' "${ITUNES_GENRE:-}" "${SPOTIFY_GENRES:-}"
