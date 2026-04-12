#!/usr/bin/env bash
# music-hook.sh — Claude Code UserPromptSubmit hook.
# Reads the current music cache and outputs a JSON envelope whose
# additionalContext field carries a <now-playing> block that future
# turns of the assistant will see in their input.
#
# Pure read by default; if the cache is stale (>10s since last sample)
# it pings music-poll.sh as a safety refresh.

set -uo pipefail

CACHE="/tmp/music-current.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL="$SCRIPT_DIR/music-poll.sh"
STALE_AFTER=10  # seconds

# Drain stdin (Claude Code sends UserPromptSubmit JSON we don't need).
cat >/dev/null

emit_empty() {
  # No music context this turn; return nothing so the prompt is unchanged.
  printf '{}\n'
  exit 0
}

# Safety refresh if cache is missing or stale.
if [[ ! -f "$CACHE" ]]; then
  bash "$POLL" >/dev/null 2>&1 || true
elif command -v jq >/dev/null 2>&1; then
  LAST_TS="$(jq -r '.lastTickAt // .elapsedAtTimestamp // 0' "$CACHE" 2>/dev/null || echo 0)"
  NOW="$(date +%s)"
  if (( NOW - LAST_TS > STALE_AFTER )); then
    bash "$POLL" >/dev/null 2>&1 || true
  fi
fi

[[ -f "$CACHE" ]] || emit_empty

# Pull fields. Missing/empty title means "nothing has played yet".
TITLE="$(jq -r '.title // ""' "$CACHE")"
[[ -z "$TITLE" ]] && emit_empty

ARTIST="$(jq -r '.artist // ""' "$CACHE")"
RATE="$(jq -r '.playbackRate // 0' "$CACHE")"
# Lyrics are still cached (so the assistant can produce them on
# request via /tmp/music-current.json) but no longer injected every
# turn — they were eating tokens and overshadowing the lighter
# title/artist/genre signal.
# Genre: prefer Spotify genres array, fall back to iTunes genre
GENRE_LINE="$(jq -r '
  if (.genres // []) | length > 0
  then .genres | join(", ")
  elif .genre // "" | length > 0
  then .genre
  else ""
  end
' "$CACHE" 2>/dev/null)"
# Behavioral signals
LISTENING_MODE="$(jq -r '.listeningMode // ""' "$CACHE" 2>/dev/null)"
RECENT_SKIPS="$(jq -r '.recentSkips // 0' "$CACHE" 2>/dev/null)"
CONSECUTIVE_REPEATS="$(jq -r '.consecutiveRepeats // 1' "$CACHE" 2>/dev/null)"

# Spotify live state (empty when non-Spotify player or not configured).
LIKED="$(jq -r        '.spotify.liked        // false' "$CACHE" 2>/dev/null)"
SHUFFLE="$(jq -r      '.spotify.shuffleState // false' "$CACHE" 2>/dev/null)"
REPEAT="$(jq -r       '.spotify.repeatState  // ""'    "$CACHE" 2>/dev/null)"
CONTEXT_TYPE="$(jq -r '.spotify.context.type // ""'    "$CACHE" 2>/dev/null)"
CONTEXT_URI="$(jq -r  '.spotify.context.uri  // ""'    "$CACHE" 2>/dev/null)"
DEVICE_NAME="$(jq -r  '.spotify.device.name  // ""'    "$CACHE" 2>/dev/null)"
# Drift inline, " · "-separated, no numbering. Skip markers preserved
# as compact "(skip)" so the assistant can still see the user is in a
# restless mood without spending a row per entry.
DRIFT_INLINE="$(jq -r '
  [.recent // [] | .[] |
    .title + (if .skipped == true then "(skip)" else "" end)
  ] | join(" · ")
' "$CACHE")"

PAUSED_TAG=""
if [[ "$RATE" == "0" ]]; then
  PAUSED_TAG=" (paused)"
fi

# Build the block. Compact: header line + drift line.
# Header: "Title" — Artist · Genre [(paused)] [· mode-tag]
{
  printf '<now-playing>\n'
  HEADER="\"$TITLE\" — $ARTIST"
  [[ -n "$GENRE_LINE" ]] && HEADER+=" · $GENRE_LINE"
  [[ -n "$PAUSED_TAG" ]] && HEADER+="$PAUSED_TAG"
  if [[ -n "$LISTENING_MODE" && "$LISTENING_MODE" != "flowing" ]]; then
    case "$LISTENING_MODE" in
      on-repeat)      HEADER+=" · on repeat (${CONSECUTIVE_REPEATS}x)" ;;
      restless)       HEADER+=" · restless (${RECENT_SKIPS} skips)" ;;
      deep-listening) HEADER+=" · same album run" ;;
    esac
  fi
  [[ "$LIKED" == "true" ]] && HEADER+=" ❤"
  printf '%s\n' "$HEADER"

  # Spotify context line: explains why this sequence is playing.
  # Skips when context is null/missing (Apple Music, manual queue, etc).
  if [[ -n "$CONTEXT_TYPE" && "$CONTEXT_TYPE" != "null" ]]; then
    printf 'Context: %s' "$CONTEXT_TYPE"
    [[ -n "$CONTEXT_URI" && "$CONTEXT_URI" != "null" ]] && printf ' (%s)' "$CONTEXT_URI"
    [[ "$SHUFFLE" == "true" ]] && printf ' · shuffle'
    case "$REPEAT" in
      track)   printf ' · repeat track' ;;
      context) printf ' · repeat all' ;;
    esac
    printf '\n'
  fi

  if [[ -n "$DRIFT_INLINE" ]]; then
    printf 'Drift: %s\n' "$DRIFT_INLINE"
  fi
  printf '</now-playing>\n'
} > /tmp/music-hook-block.$$

CONTEXT="$(cat /tmp/music-hook-block.$$)"
rm -f /tmp/music-hook-block.$$

jq -n --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
