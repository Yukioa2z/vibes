#!/usr/bin/env bash
# music-statusline.sh — Claude Code statusline.
# Doubles as the music sensor: invokes music-poll.sh first (idempotent),
# then renders 🎧 <title>  -<remaining> from the cache.
#
# Output is one line. Empty when nothing is playing — the statusline row
# will simply be blank.

set -uo pipefail

CACHE="/tmp/music-current.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL="$SCRIPT_DIR/music-poll.sh"

# Drain Claude Code's session JSON (we don't currently use it).
cat >/dev/null

bash "$POLL" >/dev/null 2>&1 || true

# Revoked authorization takes precedence over track rendering, and must
# come before the empty-title exits — a dead token is exactly when the
# cache has nothing in it, so the normal paths would render nothing at all.
AUTH_ERROR="$HOME/.cache/music/auth-error.txt"
if [[ -s "$AUTH_ERROR" ]]; then
  printf '🎧 Spotify auth revoked — re-run music-spotify-setup.py\n'
  exit 0
fi

[[ -f "$CACHE" ]] || exit 0

TITLE="$(jq -r '.title // ""' "$CACHE")"
[[ -z "$TITLE" ]] && exit 0

# Truncate long titles (podcasts, video titles) so the status row fits
# in any reasonable terminal width.
TITLE_MAX=40
TITLE_DISPLAY="$TITLE"
if (( ${#TITLE_DISPLAY} > TITLE_MAX )); then
  TITLE_DISPLAY="${TITLE_DISPLAY:0:$((TITLE_MAX - 1))}…"
fi

DURATION="$(jq -r '.duration // 0' "$CACHE")"
POSITION="$(jq -r '.playbackPosition // .playbackElapsed // .initialElapsed // 0' "$CACHE")"
LAST_TICK="$(jq -r '.lastTickAt // .firstSeenAtUnix // 0' "$CACHE")"
RATE="$(jq -r '.playbackRate // 0' "$CACHE")"
FIRST_SEEN="$(jq -r '.firstSeenAtUnix // 0' "$CACHE")"

if [[ "$RATE" == "0" ]]; then
  # Ghost-media filter: MediaRemote keeps reporting a paused browser
  # tab / old player as "current" indefinitely. If the same track has
  # been paused for >5 min without changing, hide it.
  if (( $(date +%s) - FIRST_SEEN > 300 )); then
    exit 0
  fi
  printf '🎧 %s (paused)\n' "$TITLE_DISPLAY"
  exit 0
fi

# Player is reporting rate=1 but our position has parked at duration —
# the track really finished and the app just hasn't told MediaRemote
# to flip rate to 0. Show "(ended?)" instead of a fake countdown.
if (( DURATION > 0 && POSITION >= DURATION )); then
  printf '🎧 %s (ended?)\n' "$TITLE_DISPLAY"
  exit 0
fi

NOW="$(date +%s)"
# Cap the interpolation gap. If lastTickAt is far in the past — e.g.
# the daemon was suspended while the Mac slept — naïvely adding the
# whole gap to POSITION blows past DURATION and renders -0:00. Show
# raw POSITION instead, on the assumption a stale cache means the
# track may not even be playing right now anyway.
INTERP_CAP=10
GAP=$(( NOW - LAST_TICK ))
(( GAP < 0 )) && GAP=0
(( GAP > INTERP_CAP )) && GAP=0
LIVE_ELAPSED=$(( POSITION + GAP ))
REMAINING=$(( DURATION - LIVE_ELAPSED ))
(( REMAINING < 0 )) && REMAINING=0

# Long-form (podcasts, video) shows H:MM:SS; short-form shows M:SS.
if (( REMAINING >= 3600 )); then
  HRS=$(( REMAINING / 3600 ))
  MIN=$(( (REMAINING % 3600) / 60 ))
  SEC=$(( REMAINING % 60 ))
  printf '🎧 %s  -%d:%02d:%02d\n' "$TITLE_DISPLAY" "$HRS" "$MIN" "$SEC"
else
  MIN=$(( REMAINING / 60 ))
  SEC=$(( REMAINING % 60 ))
  printf '🎧 %s  -%d:%02d\n' "$TITLE_DISPLAY" "$MIN" "$SEC"
fi
