#!/usr/bin/env bash
# vibe-hook.sh — Claude Code UserPromptSubmit hook.
# Reads the current vibe cache and outputs a JSON envelope whose
# additionalContext field carries a <now-playing> block that future
# turns of the assistant will see in their input.
#
# Pure read by default; if the cache is stale (>10s since last sample)
# it pings vibe-poll.sh as a safety refresh.

set -uo pipefail

CACHE="/tmp/vibe-current.json"
COVER="/tmp/vibe-cover.jpg"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL="$SCRIPT_DIR/vibe-poll.sh"
HISTORY_PATH="~/.cache/vibe/play_history.md"  # rendered literal for the assistant
COVER_PATH="/tmp/vibe-cover.jpg"
STALE_AFTER=10  # seconds

# Drain stdin (Claude Code sends UserPromptSubmit JSON we don't need).
cat >/dev/null

emit_empty() {
  # No vibe context this turn; return nothing so the prompt is unchanged.
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
ALBUM="$(jq -r '.album // ""' "$CACHE")"
RATE="$(jq -r '.playbackRate // 0' "$CACHE")"
LYRICS_LINES="$(jq -r '.lyrics4 // [] | .[]' "$CACHE")"
RECENT_LINES="$(jq -r '
  .recent // [] | to_entries | .[] |
  "  [-\(.key + 1)] \(.value.title) · \(.value.artist)"
' "$CACHE")"

# Cover image hint: only on FIRST hook fire after a song change.
# Note: jq's `// default` treats false as falsy too, so we use explicit
# field presence checks instead.
COVER_AVAILABLE="$(jq -r 'if .coverAvailable == true then "true" else "false" end' "$CACHE")"
COVER_SHOWN="$(jq -r 'if .coverShownToHook == false then "false" else "true" end' "$CACHE")"
INCLUDE_COVER=false
if [[ "$COVER_AVAILABLE" == "true" && "$COVER_SHOWN" == "false" && -s "$COVER" ]]; then
  INCLUDE_COVER=true
fi

PAUSED_TAG=""
if [[ "$RATE" == "0" ]]; then
  PAUSED_TAG=" (paused)"
fi

# Build the block.
{
  printf '<now-playing>\n'
  if [[ -n "$ALBUM" ]]; then
    printf '"%s" — %s (album: %s)%s\n' "$TITLE" "$ARTIST" "$ALBUM" "$PAUSED_TAG"
  else
    printf '"%s" — %s%s\n' "$TITLE" "$ARTIST" "$PAUSED_TAG"
  fi
  if [[ -n "$LYRICS_LINES" ]]; then
    printf 'Lyrics:\n'
    while IFS= read -r line; do
      printf '  %s\n' "$line"
    done <<<"$LYRICS_LINES"
  fi
  if [[ -n "$RECENT_LINES" ]]; then
    printf '\nRecent drift (last %d):\n' "$(jq -r '.recent | length' "$CACHE")"
    printf '%s\n' "$RECENT_LINES"
  fi
  if [[ "$INCLUDE_COVER" == "true" ]]; then
    printf '\n(Cover image at %s — Read it for the visual signal: palette, era, aesthetic. First mention only this turn.)\n' "$COVER_PATH"
  fi
  printf '\n(Full play history: %s)\n' "$HISTORY_PATH"
  printf '</now-playing>\n'
} > /tmp/vibe-hook-block.$$

CONTEXT="$(cat /tmp/vibe-hook-block.$$)"
rm -f /tmp/vibe-hook-block.$$

# Mark the cover as shown so subsequent hook fires for the same song
# don't repeat the hint.
if [[ "$INCLUDE_COVER" == "true" ]]; then
  TMP="$(mktemp)"
  jq '.coverShownToHook = true' "$CACHE" > "$TMP" && mv -f "$TMP" "$CACHE"
fi

jq -n --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
