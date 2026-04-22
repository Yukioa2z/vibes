#!/usr/bin/env bash
# vibe-poll.sh — core sensor for the music skill.
# Reads MediaRemote, diffs against cache, fetches lyrics on song change,
# rolls a "recent[10]" buffer, tracks pause-aware playback elapsed, and
# appends to global play history once a song has been listened to for
# >= SKIP_THRESHOLD seconds of actual playtime.
#
# Idempotent. Safe to call as often as the daemon pings (every ~2s)
# and as a safety refresh from the prompt hook.

set -uo pipefail

CACHE="/tmp/vibe-current.json"
COVER="/tmp/vibe-cover.jpg"
HISTORY="$HOME/.cache/vibe/play_history.md"
SKIP_THRESHOLD=30
RECENT_LIMIT=10
SEEK_JUMP_THRESHOLD=5  # seconds of player-elapsed disagreement → treat as seek

mkdir -p "$(dirname "$HISTORY")"

# Ad detection. Most platform ads (Spotify Free, Apple Music free tier
# preview, etc.) register through MediaRemote with brand names as both
# title and artist, with empty artist, or with explicit ad copy in the
# title. Filter these out so they don't pollute recent[] or history.
is_ad() {
  local t="${1:-}" a="${2:-}"
  [[ -z "$t" || -z "$a" ]] && { echo true; return; }
  local lt la
  lt="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]' | xargs)"
  la="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]' | xargs)"
  # title and artist identical → brand-only entry
  [[ "$lt" == "$la" ]] && { echo true; return; }
  # explicit ad keywords in title
  case "$lt" in
    *advertisement*|*ad-free*|*"ads-free"*|*"ad free"*|"shop now"*|"get more"*|*"click here"*|*"save now"*|*"learn more"*|*"sign up"*|*"call now"*|*"book now"*|*"limited time"*) echo true; return ;;
  esac
  # known ad-platform "artists"
  case "$la" in
    spotify|topsify|"spotify – advertisement") echo true; return ;;
  esac
  echo false
}

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
PREV_PLAYED=0
PREV_TICK_AT="$NOW"
if [[ -f "$CACHE" ]]; then
  PREV_TRACK_KEY="$(jq -r '.trackKey // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_LOGGED="$(jq -r '.loggedToHistory // false' "$CACHE" 2>/dev/null || echo "false")"
  PREV_TITLE="$(jq -r '.title // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_ARTIST="$(jq -r '.artist // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_RECENT="$(jq -c '.recent // []' "$CACHE" 2>/dev/null || echo "[]")"
  PREV_PLAYED="$(jq -r '.playbackElapsed // 0' "$CACHE" 2>/dev/null || echo 0)"
  PREV_TICK_AT="$(jq -r '.lastTickAt // 0' "$CACHE" 2>/dev/null || echo "$NOW")"
fi

write_cache() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  mv -f "$tmp" "$CACHE"
}

# ── Lyrics fetch: 3-tier search ──
#   1) lrclib /get  — exact artist+track+album match (best when present)
#   2) lrclib /search — fuzzy fallback when /get misses (album mismatch
#      or punctuation drift); pick first result that has plainLyrics and
#      whose artist contains ours.
#   3) NetEase public API — CJK / non-Western fallback.
fetch_lyrics4() {
  # 1) lrclib /get (exact)
  local raw plain
  raw="$(curl -fsS --max-time 2 -G "https://lrclib.net/api/get" \
    --data-urlencode "artist_name=$ARTIST" \
    --data-urlencode "track_name=$TITLE" \
    --data-urlencode "album_name=$ALBUM" 2>/dev/null || echo '{}')"
  plain="$(printf '%s' "$raw" | jq -r '.plainLyrics // ""' 2>/dev/null)"
  if [[ -n "$plain" ]]; then
    printf '%s' "$plain" | awk 'NF' | head -4 | jq -R . | jq -s .
    return
  fi

  # 2) lrclib /search (fuzzy: artist match AND normalized-title match)
  local search_resp
  search_resp="$(curl -fsS --max-time 3 -G "https://lrclib.net/api/search" \
    --data-urlencode "q=$ARTIST $TITLE" 2>/dev/null || echo '[]')"
  plain="$(printf '%s' "$search_resp" | python3 -c '
import json, sys, re
def norm(s):
    if not s: return ""
    s = s.lower()
    s = re.sub(r"\(feat\.?[^)]*\)|\[feat\.?[^\]]*\]|\(remix\)|\(remastered\)", "", s)
    s = re.sub(r"[^\w\s]", "", s)
    return re.sub(r"\s+", " ", s).strip()
try:
    arr = json.load(sys.stdin)
except Exception:
    sys.exit(0)
artist_n = norm(sys.argv[1])
title_n  = norm(sys.argv[2])
for r in arr:
    a = norm(r.get("artistName"))
    t = norm(r.get("trackName"))
    pl = r.get("plainLyrics")
    if not pl: continue
    artist_match = artist_n in a or a in artist_n
    title_match  = title_n in t or t in title_n
    if artist_match and title_match:
        print(pl)
        sys.exit(0)
' "$ARTIST" "$TITLE" 2>/dev/null)"
  if [[ -n "$plain" ]]; then
    printf '%s' "$plain" | awk 'NF' | head -4 | jq -R . | jq -s .
    return
  fi

  # 3) NetEase public API fallback (anonymous, no auth) for CJK coverage
  local query="$ARTIST $TITLE"
  local search
  search="$(curl -fsS --max-time 3 -G "https://music.163.com/api/search/get" \
    -H "Referer: https://music.163.com/" \
    --data-urlencode "s=$query" \
    --data-urlencode "type=1" \
    --data-urlencode "limit=1" 2>/dev/null || echo '{}')"
  local songid
  songid="$(printf '%s' "$search" | jq -r '.result.songs[0].id // empty' 2>/dev/null)"
  if [[ -n "$songid" ]]; then
    local lrc
    lrc="$(curl -fsS --max-time 3 "https://music.163.com/api/song/lyric?id=${songid}&lv=-1&tv=-1" \
      -H "Referer: https://music.163.com/" 2>/dev/null || echo '{}')"
    local raw_lrc
    raw_lrc="$(printf '%s' "$lrc" | jq -r '.lrc.lyric // ""' 2>/dev/null)"
    if [[ -n "$raw_lrc" ]]; then
      # LRC is "[mm:ss.xx]words" — strip timestamps, drop blanks, drop LRC
      # ID3 meta (ti:/ar:/al:), and drop ALL credit lines (heuristic: any
      # line whose pre-colon prefix is ≤ 8 chars of CJK/letters and is
      # followed by ":" or "：" — that pattern is universally "role : name"
      # in NetEase lyrics, never lyric content).
      printf '%s' "$raw_lrc" \
        | sed -E 's/\[[0-9:.]+\]//g' \
        | python3 -c '
import sys, re, json
LRC_META = re.compile(r"^[A-Za-z]{2,4}\s*:\s*\S")
CREDIT   = re.compile(r"^\s*\S{1,8}\s*[:：]\s*\S")
out = []
for line in sys.stdin:
    s = line.strip()
    if not s: continue
    if LRC_META.match(s) or CREDIT.match(s): continue
    out.append(s)
    if len(out) >= 4: break
print(json.dumps(out, ensure_ascii=False))
'
      return
    fi
  fi

  printf '[]'
}

if [[ "$TRACK_KEY" != "$PREV_TRACK_KEY" ]]; then
  # ── New song ─────────────────────────────────────────────────────────
  # Push previous track onto the front of the recent buffer (cap at
  # RECENT_LIMIT) — but skip ads to keep drift signal clean.
  if [[ -n "$PREV_TRACK_KEY" && "$(is_ad "$PREV_TITLE" "$PREV_ARTIST")" == "false" ]]; then
    NEW_RECENT="$(jq -c \
      --arg t "$PREV_TITLE" \
      --arg a "$PREV_ARTIST" \
      --argjson ts "$NOW" \
      "[{title:\$t, artist:\$a, ts:\$ts}] + . | .[0:${RECENT_LIMIT}]" \
      <<<"$PREV_RECENT")"
  else
    NEW_RECENT="$PREV_RECENT"
  fi

  LYRICS_4="$(fetch_lyrics4)"
  [[ -z "$LYRICS_4" ]] && LYRICS_4="[]"

  # Save the cover artwork as a JPEG so the hook can hint at its path
  # and the assistant can Read it for a visual signal (color palette,
  # era, aesthetic). Best-effort; missing artwork is silent.
  nowplaying-cli get-raw 2>/dev/null | python3 -c '
import json, sys, base64
try:
    d = json.load(sys.stdin)
    art = d.get("kMRMediaRemoteNowPlayingInfoArtworkData")
    if art:
        open("'"$COVER"'", "wb").write(base64.b64decode(art))
except Exception:
    pass
' 2>/dev/null || true
  COVER_AVAILABLE=false
  [[ -s "$COVER" ]] && COVER_AVAILABLE=true

  jq -n \
    --arg title "$TITLE" \
    --arg artist "$ARTIST" \
    --arg album "$ALBUM" \
    --arg trackKey "$TRACK_KEY" \
    --argjson duration "$DURATION" \
    --argjson initialElapsed "$ELAPSED" \
    --argjson playbackElapsed "$ELAPSED" \
    --argjson lastTickAt "$NOW" \
    --argjson firstSeenAtUnix "$NOW" \
    --argjson playbackRate "$RATE" \
    --argjson lyrics4 "$LYRICS_4" \
    --argjson recent "$NEW_RECENT" \
    --argjson coverAvailable "$COVER_AVAILABLE" \
    --arg startedAt "$ISO_NOW" \
    '{title:$title, artist:$artist, album:$album, trackKey:$trackKey,
      duration:$duration, initialElapsed:$initialElapsed,
      playbackElapsed:$playbackElapsed, lastTickAt:$lastTickAt,
      firstSeenAtUnix:$firstSeenAtUnix,
      playbackRate:$playbackRate, lyrics4:$lyrics4, recent:$recent,
      coverAvailable:$coverAvailable, coverShownToHook:false,
      startedAt:$startedAt, loggedToHistory:false}' | write_cache

else
  # ── Same song ────────────────────────────────────────────────────────
  # Pause-aware advance: only accumulate playtime when rate=1.
  DELTA=$(( NOW - PREV_TICK_AT ))
  if (( DELTA < 0 )); then DELTA=0; fi
  if (( RATE == 1 )); then
    NEW_PLAYED=$(( PREV_PLAYED + DELTA ))
  else
    NEW_PLAYED=$PREV_PLAYED
  fi

  # Seek detection: if the player reports a fresh elapsed value that
  # disagrees with our local count by more than SEEK_JUMP_THRESHOLD,
  # trust the player and resync. (Players that always report 0 won't
  # trigger this; players that do report will keep us aligned.)
  if (( ELAPSED > 0 )); then
    DIFF=$(( ELAPSED > NEW_PLAYED ? ELAPSED - NEW_PLAYED : NEW_PLAYED - ELAPSED ))
    if (( DIFF > SEEK_JUMP_THRESHOLD )); then
      NEW_PLAYED=$ELAPSED
    fi
  fi

  jq \
    --argjson playbackElapsed "$NEW_PLAYED" \
    --argjson lastTickAt "$NOW" \
    --argjson playbackRate "$RATE" \
    '.playbackElapsed = $playbackElapsed
     | .lastTickAt = $lastTickAt
     | .playbackRate = $playbackRate' \
    "$CACHE" | write_cache

  # First crossing of the skip threshold (using actual played time, not
  # wall time). Skip ads — they shouldn't pollute long-term history.
  if [[ "$PREV_LOGGED" == "false" && "$NEW_PLAYED" -ge "$SKIP_THRESHOLD" \
        && "$(is_ad "$TITLE" "$ARTIST")" == "false" ]]; then
    printf '%s\n' "- ${ISO_NOW} — ${TITLE} · ${ARTIST}" >> "$HISTORY"
    jq '.loggedToHistory = true' "$CACHE" | write_cache
  fi
fi
