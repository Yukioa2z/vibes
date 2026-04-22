#!/usr/bin/env bash
# vibe-enrich.sh — Enrich a track with genre metadata.
#
# Three tiers:
#   1. Spotify API  → artist genres (requires one-time OAuth setup)
#   2. iTunes Search API → primaryGenreName (free, no auth)
#   3. Neither → empty (graceful fallback)
#
# Usage: vibe-enrich.sh "Artist" "Title"
# Outputs JSON: {"genre":"Rock","genres":["indie rock","art rock"]}
#
# Called by vibe-poll.sh on song change. Each API call is bounded by
# --max-time so a slow/down service can't stall the poll cycle.

set -uo pipefail

ARTIST="${1:-}"
TITLE="${2:-}"
SPOTIFY_CONFIG="$HOME/.config/vibe/spotify.json"

[[ -z "$ARTIST" || -z "$TITLE" ]] && { echo '{}'; exit 0; }

SPOTIFY_GENRES=""
ITUNES_GENRE=""

# ── 1. Spotify (if configured) ────────────────────────────────────
spotify_enrich() {
  [[ -f "$SPOTIFY_CONFIG" ]] || return

  local access_token expires_at now
  access_token="$(jq -r '.access_token // ""' "$SPOTIFY_CONFIG" 2>/dev/null)"
  expires_at="$(jq -r '.expires_at // 0' "$SPOTIFY_CONFIG" 2>/dev/null)"
  now="$(date +%s)"

  # Refresh token if expired
  if (( now >= expires_at )); then
    local refresh_token client_id
    refresh_token="$(jq -r '.refresh_token // ""' "$SPOTIFY_CONFIG" 2>/dev/null)"
    client_id="$(jq -r '.client_id // ""' "$SPOTIFY_CONFIG" 2>/dev/null)"
    [[ -z "$refresh_token" || -z "$client_id" ]] && return

    local refresh_resp
    refresh_resp="$(curl -fsS --max-time 5 -X POST "https://accounts.spotify.com/api/token" \
      -d "grant_type=refresh_token" \
      -d "refresh_token=$refresh_token" \
      -d "client_id=$client_id" 2>/dev/null || echo '{}')"

    access_token="$(printf '%s' "$refresh_resp" | jq -r '.access_token // ""')"
    [[ -z "$access_token" ]] && return

    local new_refresh expires_in
    new_refresh="$(printf '%s' "$refresh_resp" | jq -r '.refresh_token // ""')"
    expires_in="$(printf '%s' "$refresh_resp" | jq -r '.expires_in // 3600')"

    local tmp; tmp="$(mktemp)"
    jq --arg at "$access_token" \
       --arg rt "${new_refresh:-$refresh_token}" \
       --argjson ea "$((now + expires_in))" \
       '.access_token = $at | .refresh_token = (if $rt != "" then $rt else .refresh_token end) | .expires_at = $ea' \
       "$SPOTIFY_CONFIG" > "$tmp"
    mv -f "$tmp" "$SPOTIFY_CONFIG"
  fi

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
