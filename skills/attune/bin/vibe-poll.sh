#!/usr/bin/env bash
# vibe-poll.sh — core sensor for the attune skill.
# Reads MediaRemote, diffs against cache, fetches lyrics on song change,
# rolls a "recent[10]" buffer, and appends to global play history once
# a song has been listened to for >= SKIP_THRESHOLD seconds.
#
# Idempotent. Safe to call as often as the statusline pings (every ~2s)
# and also as a safety refresh from the prompt hook.

set -uo pipefail

CACHE="/tmp/vibe-current.json"
HISTORY="$HOME/.cache/vibe/play_history.md"
SKIP_THRESHOLD=30
RECENT_LIMIT=10

mkdir -p "$(dirname "$HISTORY")"

# Pull six fields, one per line, in this exact order.
RAW="$(nowplaying-cli get title artist album duration elapsedTime playbackRate 2>/dev/null || true)"
TITLE="$(printf '%s\n' "$RAW" | sed -n '1p')"
ARTIST="$(printf '%s\n' "$RAW" | sed -n '2p')"
ALBUM="$(printf '%s\n' "$RAW" | sed -n '3p')"
DURATION_RAW="$(printf '%s\n' "$RAW" | sed -n '4p')"
ELAPSED_RAW="$(printf '%s\n' "$RAW" | sed -n '5p')"
RATE_RAW="$(printf '%s\n' "$RAW" | sed -n '6p')"

# Coerce numeric fields safely. nowplaying-cli prints empty/null for missing.
to_num() {
  local v="${1:-0}"
  [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && printf '%.0f' "$v" || echo 0
}
DURATION="$(to_num "$DURATION_RAW")"
ELAPSED="$(to_num "$ELAPSED_RAW")"
RATE="$(to_num "$RATE_RAW")"

# Nothing playing → leave the cache untouched (preserves "vibe drift" of last song).
if [[ -z "$TITLE" || "$TITLE" == "null" ]]; then
  exit 0
fi

NOW="$(date +%s)"
TRACK_KEY="${TITLE}::${ARTIST}"
ISO_NOW="$(date -u +%Y-%m-%dT%H:%M)"

PREV_TRACK_KEY=""
PREV_LOGGED="false"
PREV_TITLE=""
PREV_ARTIST=""
PREV_RECENT="[]"
if [[ -f "$CACHE" ]]; then
  PREV_TRACK_KEY="$(jq -r '.trackKey // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_LOGGED="$(jq -r '.loggedToHistory // false' "$CACHE" 2>/dev/null || echo "false")"
  PREV_TITLE="$(jq -r '.title // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_ARTIST="$(jq -r '.artist // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_RECENT="$(jq -c '.recent // []' "$CACHE" 2>/dev/null || echo "[]")"
fi

write_cache() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  mv -f "$tmp" "$CACHE"
}

if [[ "$TRACK_KEY" != "$PREV_TRACK_KEY" ]]; then
  # ── New song ─────────────────────────────────────────────────────────
  # Push previous track onto the front of the recent buffer (cap at RECENT_LIMIT).
  if [[ -n "$PREV_TRACK_KEY" ]]; then
    NEW_RECENT="$(jq -c \
      --arg t "$PREV_TITLE" \
      --arg a "$PREV_ARTIST" \
      --argjson ts "$NOW" \
      "[{title:\$t, artist:\$a, ts:\$ts}] + . | .[0:${RECENT_LIMIT}]" \
      <<<"$PREV_RECENT")"
  else
    NEW_RECENT="$PREV_RECENT"
  fi

  # Best-effort lyrics from lrclib (2s timeout; failure is silent).
  LYRICS_RAW="$(curl -fsS --max-time 2 -G "https://lrclib.net/api/get" \
    --data-urlencode "artist_name=$ARTIST" \
    --data-urlencode "track_name=$TITLE" \
    --data-urlencode "album_name=$ALBUM" 2>/dev/null || echo '{}')"
  LYRICS_4="$(printf '%s' "$LYRICS_RAW" \
    | jq -r '.plainLyrics // ""' \
    | awk 'NF' \
    | head -4 \
    | jq -R . | jq -s . 2>/dev/null || echo '[]')"
  [[ -z "$LYRICS_4" ]] && LYRICS_4="[]"

  jq -n \
    --arg title "$TITLE" \
    --arg artist "$ARTIST" \
    --arg album "$ALBUM" \
    --arg trackKey "$TRACK_KEY" \
    --argjson duration "$DURATION" \
    --argjson initialElapsed "$ELAPSED" \
    --argjson firstSeenAtUnix "$NOW" \
    --argjson elapsedAt "$ELAPSED" \
    --argjson elapsedAtTimestamp "$NOW" \
    --argjson playbackRate "$RATE" \
    --argjson lyrics4 "$LYRICS_4" \
    --argjson recent "$NEW_RECENT" \
    --arg startedAt "$ISO_NOW" \
    '{title:$title, artist:$artist, album:$album, trackKey:$trackKey,
      duration:$duration, initialElapsed:$initialElapsed, firstSeenAtUnix:$firstSeenAtUnix,
      elapsedAt:$elapsedAt, elapsedAtTimestamp:$elapsedAtTimestamp,
      playbackRate:$playbackRate, lyrics4:$lyrics4, recent:$recent,
      startedAt:$startedAt, loggedToHistory:false}' | write_cache

else
  # ── Same song ────────────────────────────────────────────────────────
  jq \
    --argjson elapsedAt "$ELAPSED" \
    --argjson elapsedAtTimestamp "$NOW" \
    --argjson playbackRate "$RATE" \
    '.elapsedAt = $elapsedAt
     | .elapsedAtTimestamp = $elapsedAtTimestamp
     | .playbackRate = $playbackRate' \
    "$CACHE" | write_cache

  # First crossing of the skip threshold → log to history exactly once.
  if [[ "$PREV_LOGGED" == "false" && "$ELAPSED" -ge "$SKIP_THRESHOLD" ]]; then
    printf '%s\n' "- ${ISO_NOW} — ${TITLE} · ${ARTIST}" >> "$HISTORY"
    jq '.loggedToHistory = true' "$CACHE" | write_cache
  fi
fi
