#!/usr/bin/env bash
# music-player-state.sh — fetch live Spotify player state for one track change.
#
# Called by music-poll.sh on every track-change event. ONE round trip:
# /me/player gives us is_playing + shuffle + repeat + device + context +
# the Spotify track id. We then cross-ref the id against the local
# liked_tracks.json cache (refreshed by the poll daemon every ~30min via
# music-history-sync.sh library) to derive `liked: true/false`.
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

# Source gate: /me/player reflects Spotify's last server-side session,
# which persists after the user swaps to a non-Spotify player (YouTube
# in a browser, Apple Music, etc.). Without this check, shuffle/repeat/
# context/liked from a stale Spotify session leak into a now-playing
# block that is actually showing a YouTube track. Bail early whenever
# MediaRemote tells us the current source isn't the Spotify desktop app.
SRC_BUNDLE="${MUSIC_SOURCE_BUNDLE_ID:-}"
if [[ -n "$SRC_BUNDLE" && "$SRC_BUNDLE" != "com.spotify.client" ]]; then
  emit_empty
fi

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

# Second-layer check: even when Spotify is the focused MediaRemote
# source, the server-side /me/player can lag or report a different
# track than MediaRemote (e.g. Spotify paused + another Spotify client
# resumed on a different device right before we swapped apps). If the
# reported Spotify track name / artist disagrees with what we're about
# to display, assume the Web API view is stale and bail.
api_title="$(printf '%s' "$PLAYER" | jq -r '.item.name // ""')"
api_artist="$(printf '%s' "$PLAYER" | jq -r '[.item.artists // [] | .[].name] | join(", ")')"
mr_title="${MUSIC_CURRENT_TITLE:-}"
mr_artist="${MUSIC_CURRENT_ARTIST:-}"
if [[ -n "$mr_title" && -n "$api_title" ]]; then
  # Lowercase compare to dodge casing drift.
  lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
  if [[ "$(lc "$api_title")" != "$(lc "$mr_title")" ]]; then
    emit_empty
  fi
  # Artist is optional on the MR side (some YouTube tabs emit empty
  # artist and a bundle we don't gate on); only enforce when both sides
  # have something.
  if [[ -n "$mr_artist" && -n "$api_artist" \
        && "$(lc "$api_artist")" != "$(lc "$mr_artist")" ]]; then
    # Weak mismatch (e.g. "U137" vs "U137, Hollow Coves") — allow if one
    # contains the other; otherwise bail.
    case "$(lc "$api_artist")" in
      *"$(lc "$mr_artist")"*) : ;;
      *)
        case "$(lc "$mr_artist")" in
          *"$(lc "$api_artist")"*) : ;;
          *) emit_empty ;;
        esac
        ;;
    esac
  fi
fi

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
