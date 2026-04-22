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
PLAYED="$(jq -r '.playbackElapsed // .initialElapsed // 0' "$CACHE")"
LAST_TICK="$(jq -r '.lastTickAt // .firstSeenAtUnix // 0' "$CACHE")"
RATE="$(jq -r '.playbackRate // 0' "$CACHE")"

if [[ "$RATE" == "0" ]]; then
  printf '🎧 %s (paused)\n' "$TITLE"
  exit 0
fi

NOW="$(date +%s)"
# playbackElapsed is the cache's authoritative played-seconds counter.
# Interpolate forward from lastTickAt so the displayed countdown stays
# fresh between daemon polls. Pause/seek are already handled in poll.
LIVE_ELAPSED=$(( PLAYED + (NOW - LAST_TICK) ))
REMAINING=$(( DURATION - LIVE_ELAPSED ))
(( REMAINING < 0 )) && REMAINING=0

MIN=$(( REMAINING / 60 ))
SEC=$(( REMAINING % 60 ))
printf '🎧 %s  -%d:%02d\n' "$TITLE" "$MIN" "$SEC"
