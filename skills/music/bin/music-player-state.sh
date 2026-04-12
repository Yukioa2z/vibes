#!/usr/bin/env bash
# music-player-state.sh — fetch live Spotify player state for one track change.
#
# Called by music-poll.sh on every track-change event. ONE round trip:
# /me/player gives us is_playing + shuffle + repeat + device + context +
# the Spotify track id. We then cross-ref the id against the local
# liked_tracks.json cache (refreshed periodically by music-history-sync.sh
# library) to derive `liked: true/false`.
#
# Outputs a JSON object meant to be jq-merged into /tmp/music-current.json.
# All keys are namespaced under `spotify` to avoid clashing with the
# nowplaying-cli view of the world.
#
# On any failure (no token, non-Spotify player, network down, 204 no
# content), prints {} and exits 0 — the poll loop continues normally.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=music-spotify-auth.sh
source "$SCRIPT_DIR/music-spotify-auth.sh"

LIKED_CACHE="$HOME/.cache/music/liked_tracks.json"

emit_empty() { printf '%s\n' '{}'; exit 0; }

token="$(spotify_get_token)" || emit_empty

# /me/player returns 204 (empty body) when no Spotify session is active.
# Capture status separately so we can distinguish 204 from a real 200.
body="$(curl --noproxy '*' -fsS --max-time 4 \
  -o /tmp/music-player.body -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  "https://api.spotify.com/v1/me/player" 2>/dev/null || echo 000)"
[[ "$body" != "200" ]] && { rm -f /tmp/music-player.body; emit_empty; }

PLAYER="$(cat /tmp/music-player.body 2>/dev/null)"
rm -f /tmp/music-player.body
[[ -z "$PLAYER" ]] && emit_empty

# Extract just what we'll bake into the cache.
parsed="$(printf '%s' "$PLAYER" | jq -c '{
  spotifyTrackId:  .item.id,
  spotifyTrackUri: .item.uri,
  isPlaying:       .is_playing,
  shuffleState:    .shuffle_state,
  repeatState:     .repeat_state,
  device: {
    name: .device.name,
    type: .device.type,
    volumePercent: .device.volume_percent
  },
  context: {
    type: (.context.type // null),
    uri:  (.context.uri  // null)
  }
}')"

# Liked lookup against the local cache.
liked=false
if [[ -f "$LIKED_CACHE" ]]; then
  tid="$(printf '%s' "$parsed" | jq -r '.spotifyTrackId // empty')"
  if [[ -n "$tid" ]]; then
    if jq -e --arg id "$tid" 'any(.[]; .id == $id)' "$LIKED_CACHE" >/dev/null 2>&1; then
      liked=true
    fi
  fi
fi

# Wrap under `spotify` namespace + add liked.
printf '%s' "$parsed" | jq -c --argjson liked "$liked" '{spotify: (. + {liked: $liked})}'
