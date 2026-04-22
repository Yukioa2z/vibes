#!/usr/bin/env bash
# vibe-statusline.sh — Claude Code statusline.
# Doubles as the music sensor: invokes vibe-poll.sh first (idempotent),
# then renders 🎧 <title>  -<remaining> from the cache.
#
# Output is one line. Empty when nothing is playing — the statusline row
# will simply be blank.

set -uo pipefail

CACHE="/tmp/vibe-current.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL="$SCRIPT_DIR/vibe-poll.sh"

# Drain Claude Code's session JSON (we don't currently use it).
cat >/dev/null

bash "$POLL" >/dev/null 2>&1 || true

[[ -f "$CACHE" ]] || exit 0

TITLE="$(jq -r '.title // ""' "$CACHE")"
[[ -z "$TITLE" ]] && exit 0

DURATION="$(jq -r '.duration // 0' "$CACHE")"
INITIAL_ELAPSED="$(jq -r '.initialElapsed // .elapsedAt // 0' "$CACHE")"
FIRST_SEEN="$(jq -r '.firstSeenAtUnix // .elapsedAtTimestamp // 0' "$CACHE")"
RATE="$(jq -r '.playbackRate // 0' "$CACHE")"

if [[ "$RATE" == "0" ]]; then
  printf '🎧 %s (paused)\n' "$TITLE"
  exit 0
fi

NOW="$(date +%s)"
# Interpolate from when we first saw the song. Works even when the player
# never updates elapsedTime (e.g. some browser tabs and third-party players).
LIVE_ELAPSED=$(( INITIAL_ELAPSED + (NOW - FIRST_SEEN) ))
REMAINING=$(( DURATION - LIVE_ELAPSED ))
(( REMAINING < 0 )) && REMAINING=0

MIN=$(( REMAINING / 60 ))
SEC=$(( REMAINING % 60 ))
printf '🎧 %s  -%d:%02d\n' "$TITLE" "$MIN" "$SEC"
