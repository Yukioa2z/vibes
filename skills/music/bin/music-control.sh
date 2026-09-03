#!/usr/bin/env bash
# music-control.sh — control Spotify playback from Claude Code.
#
# Designed to be called by Claude through Bash. Every command prints a
# one-line human-readable result on success or error. Claude reads it.
#
# Most playback commands require Spotify Premium (a Spotify rule, not
# ours). 403 with PREMIUM_REQUIRED is reported as such.
#
# Subcommands:
#   next                       skip to next track
#   prev                       previous track (Spotify replays current first
#                              if elapsed > ~3s, then jumps back on second call)
#   pause                      pause playback
#   play [uri]                 resume, or jump to spotify:track:... /
#                              spotify:album:... / spotify:playlist:... uri
#   seek <ms>                  jump to position in ms
#   vol <0-100>                set volume (whole percent)
#   shuffle <on|off>           toggle shuffle
#   repeat <off|track|context> set repeat mode
#   queue <uri>                add track to queue
#   save                       add current track to "Liked Songs"
#   unsave                     remove current track from "Liked Songs"
#   devices                    list available playback devices
#   transfer <device_id|name>  move playback to a different device
#
# All write actions also update the local saved-tracks cache so
# music-poll.sh sees Liked changes without waiting for the next sync.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=music-spotify-auth.sh
source "$SCRIPT_DIR/music-spotify-auth.sh"

LIKED_CACHE="$HOME/.cache/music/liked_tracks.json"
HISTORY="$HOME/.cache/music/play_history.md"
API="https://api.spotify.com/v1"

history_event() {
  local msg="$1"
  [[ -f "$HISTORY" ]] || return 0
  # Local time with explicit offset, matching music-poll.sh history lines.
  local iso; iso="$(date +%Y-%m-%dT%H:%M%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
  printf '> %s — %s\n' "$iso" "$msg" >> "$HISTORY"
}

ok()   { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

token() {
  local t; t="$(spotify_get_token)" || fail "Spotify not configured (run music-spotify-setup.py)"
  printf '%s' "$t"
}

# Run a request, return body. On non-2xx status, fail with parsed error.
api_call() {
  local method="$1" path="$2"; shift 2
  local data="${1:-}"
  local tok; tok="$(token)"
  local body status
  local args=(-s -o /tmp/music-control.body -w '%{http_code}' \
              --noproxy '*' --max-time 10 \
              -X "$method" \
              -H "Authorization: Bearer $tok")
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data "$data")

  status="$(curl "${args[@]}" "$API$path")"
  body="$(cat /tmp/music-control.body 2>/dev/null)"; rm -f /tmp/music-control.body

  case "$status" in
    20[0-9])
      printf '%s' "$body"
      return 0
      ;;
    401)
      fail "401 Unauthorized — token may be invalid; try re-running music-spotify-setup.py"
      ;;
    403)
      local reason; reason="$(printf '%s' "$body" | jq -r '.error.reason // .error.message // "Forbidden"' 2>/dev/null)"
      if [[ "$reason" == "PREMIUM_REQUIRED" ]]; then
        fail "PREMIUM_REQUIRED — playback control needs Spotify Premium"
      fi
      fail "403 — $reason"
      ;;
    404)
      local reason; reason="$(printf '%s' "$body" | jq -r '.error.reason // .error.message // "Not found"' 2>/dev/null)"
      if [[ "$reason" == "NO_ACTIVE_DEVICE" ]]; then
        fail "NO_ACTIVE_DEVICE — open Spotify on a device first, or use 'transfer'"
      fi
      fail "404 — $reason"
      ;;
    429)
      local retry; retry="$(printf '%s' "$body" | jq -r '.error.message // ""')"
      fail "429 rate-limited — $retry"
      ;;
    *)
      local msg; msg="$(printf '%s' "$body" | jq -r '.error.message // .' 2>/dev/null | head -c 200)"
      fail "HTTP $status — $msg"
      ;;
  esac
}

# Get current track id (for save / unsave). Empty if nothing playing.
current_track_id() {
  local body; body="$(api_call GET /me/player/currently-playing)" || return 1
  printf '%s' "$body" | jq -r '.item.id // empty'
}

current_track_meta() {
  local body; body="$(api_call GET /me/player/currently-playing)" || return 1
  printf '%s' "$body" | jq -c '{
    id: .item.id,
    name: .item.name,
    artist: ([.item.artists[].name] | join(", ")),
    album: .item.album.name
  }'
}

# Resolve a device argument (id OR name substring) to a device id.
resolve_device() {
  local q="$1" body; body="$(api_call GET /me/player/devices)"
  # exact id match first, then case-insensitive name substring
  local id
  id="$(printf '%s' "$body" | jq -r --arg q "$q" '.devices[] | select(.id == $q) | .id' | head -1)"
  if [[ -z "$id" ]]; then
    id="$(printf '%s' "$body" | jq -r --arg q "$q" '.devices[] | select(.name | ascii_downcase | contains($q | ascii_downcase)) | .id' | head -1)"
  fi
  [[ -n "$id" ]] || fail "no device matching: $q"
  printf '%s' "$id"
}

# After a save/unsave, update the local liked_tracks.json so poll picks
# it up on the next track-change tick (no need to wait for full sync).
liked_cache_add() {
  local id="$1" name="$2" artist="$3" album="$4"
  [[ -f "$LIKED_CACHE" ]] || printf '[]' > "$LIKED_CACHE"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" --arg name "$name" --arg artist "$artist" --arg album "$album" --arg ts "$now" \
    '[{id:$id, name:$name, artist:$artist, album:$album, added_at:$ts}] + (map(select(.id != $id)))' \
    "$LIKED_CACHE" > "$tmp"
  mv -f "$tmp" "$LIKED_CACHE"
}

liked_cache_remove() {
  local id="$1"
  [[ -f "$LIKED_CACHE" ]] || return 0
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" 'map(select(.id != $id))' "$LIKED_CACHE" > "$tmp"
  mv -f "$tmp" "$LIKED_CACHE"
}

# ── subcommands ─────────────────────────────────────────────────────
cmd_next()  { api_call POST /me/player/next     >/dev/null; ok "→ next"; }
cmd_prev()  { api_call POST /me/player/previous >/dev/null; ok "← previous"; }
cmd_pause() { api_call PUT  /me/player/pause    >/dev/null; ok "paused"; }

cmd_play() {
  if [[ $# -eq 0 ]]; then
    api_call PUT /me/player/play >/dev/null
    ok "▶ resumed"
    return
  fi
  local uri="$1" body
  case "$uri" in
    spotify:track:*)         body="$(jq -nc --arg u "$uri" '{uris:[$u]}')" ;;
    spotify:album:*|\
    spotify:playlist:*|\
    spotify:artist:*)        body="$(jq -nc --arg u "$uri" '{context_uri:$u}')" ;;
    *) fail "unknown uri: $uri (expected spotify:track:/album:/playlist:/artist:...)" ;;
  esac
  api_call PUT /me/player/play "$body" >/dev/null
  ok "▶ playing $uri"
}

cmd_seek() {
  local ms="${1:?usage: seek <ms>}"
  [[ "$ms" =~ ^[0-9]+$ ]] || fail "seek requires non-negative integer ms"
  api_call PUT "/me/player/seek?position_ms=$ms" >/dev/null
  ok "seeked to ${ms}ms"
}

cmd_vol() {
  local v="${1:?usage: vol <0-100>}"
  [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 0 && v <= 100 )) || fail "volume must be 0-100"
  api_call PUT "/me/player/volume?volume_percent=$v" >/dev/null
  ok "volume → $v%"
}

cmd_shuffle() {
  local s="${1:?usage: shuffle <on|off>}"
  case "$s" in
    on|true|1)  s=true  ;;
    off|false|0) s=false ;;
    *) fail "shuffle expects on|off" ;;
  esac
  api_call PUT "/me/player/shuffle?state=$s" >/dev/null
  ok "shuffle → $s"
}

cmd_repeat() {
  local r="${1:?usage: repeat <off|track|context>}"
  case "$r" in off|track|context) ;; *) fail "repeat expects off|track|context" ;; esac
  api_call PUT "/me/player/repeat?state=$r" >/dev/null
  ok "repeat → $r"
}

cmd_queue() {
  local uri="${1:?usage: queue <spotify:track:...>}"
  [[ "$uri" == spotify:track:* ]] || fail "queue accepts spotify:track:... only"
  # URL-encode the colons (curl --data-urlencode is for body, not query)
  local enc; enc="$(printf '%s' "$uri" | jq -sRr @uri)"
  api_call POST "/me/player/queue?uri=$enc" >/dev/null
  ok "queued $uri"
}

cmd_save() {
  local meta; meta="$(current_track_meta)" || fail "nothing playing"
  local id name artist album
  id="$(    printf '%s' "$meta" | jq -r .id)"
  name="$(  printf '%s' "$meta" | jq -r .name)"
  artist="$(printf '%s' "$meta" | jq -r .artist)"
  album="$( printf '%s' "$meta" | jq -r .album)"
  [[ -n "$id" ]] || fail "current track has no id (ad? podcast?)"
  api_call PUT "/me/tracks?ids=$id" >/dev/null
  liked_cache_add "$id" "$name" "$artist" "$album"
  history_event "liked $name · $artist"
  ok "❤ saved: $name · $artist"
}

cmd_unsave() {
  local meta; meta="$(current_track_meta)" || fail "nothing playing"
  local id name artist
  id="$(    printf '%s' "$meta" | jq -r .id)"
  name="$(  printf '%s' "$meta" | jq -r .name)"
  artist="$(printf '%s' "$meta" | jq -r .artist)"
  [[ -n "$id" ]] || fail "current track has no id"
  api_call DELETE "/me/tracks?ids=$id" >/dev/null
  liked_cache_remove "$id"
  history_event "unliked $name · $artist"
  ok "removed from Liked: $name · $artist"
}

cmd_devices() {
  local body; body="$(api_call GET /me/player/devices)"
  printf '%s' "$body" | jq -r '.devices[] | "\(if .is_active then "*" else " " end) \(.id) — \(.name) (\(.type))\(if .volume_percent then "  vol=\(.volume_percent)%" else "" end)"'
}

cmd_transfer() {
  local q="${1:?usage: transfer <device_id|name_substring>}"
  local id; id="$(resolve_device "$q")"
  local body; body="$(jq -nc --arg id "$id" '{device_ids:[$id], play:true}')"
  api_call PUT /me/player "$body" >/dev/null
  ok "transferred to $id"
}

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  next)     cmd_next ;;
  prev|previous) cmd_prev ;;
  pause)    cmd_pause ;;
  play)     cmd_play "$@" ;;
  seek)     cmd_seek "$@" ;;
  vol|volume) cmd_vol "$@" ;;
  shuffle)  cmd_shuffle "$@" ;;
  repeat)   cmd_repeat "$@" ;;
  queue)    cmd_queue "$@" ;;
  save|like) cmd_save ;;
  unsave|unlike) cmd_unsave ;;
  devices)  cmd_devices ;;
  transfer) cmd_transfer "$@" ;;
  ""|-h|--help|help) usage 0 ;;
  *) printf 'unknown command: %s\n\n' "$cmd" >&2; usage 2 ;;
esac
