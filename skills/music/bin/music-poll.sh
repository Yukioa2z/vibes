#!/usr/bin/env bash
# music-poll.sh — core sensor for the music skill.
# Reads MediaRemote, diffs against cache, rolls a "recent[10]" buffer,
# tracks pause-aware playback elapsed, and appends to global play
# history once a song has been listened to for >= SKIP_THRESHOLD
# seconds of actual playtime.
#
# Idempotent. Safe to call as often as the daemon pings (every ~2s)
# and as a safety refresh from the prompt hook.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="/tmp/music-current.json"
COVER="/tmp/music-cover.jpg"
HISTORY="$HOME/.cache/music/play_history.md"
LOCK="/tmp/music-poll.lock"
LOCK_PID="$LOCK/pid"
SKIP_THRESHOLD=30
RECENT_LIMIT=10
LOCK_STALE_AFTER=30  # seconds; backstop for the rare case where a poll
                     # owner is alive but truly hung (we'd rather steal
                     # the lock than block forever)

# ── Single-writer lock (mkdir is POSIX-atomic) ───────────────────────
# The launchd daemon runs every 2s; the prompt hook may call us as a
# safety refresh; the statusline used to. Without a lock, two pollers
# can both cross the SKIP_THRESHOLD between read and write and append
# the same history line.
#
# Lock is `mkdir $LOCK` plus a `pid` file inside. SIGKILL doesn't fire
# the EXIT trap, so on watchdog kill the lock dir survives — the next
# poll detects this by checking whether the recorded PID is still
# alive (kill -0). If not, the lock is reclaimed immediately rather
# than blocking until LOCK_STALE_AFTER seconds elapse.
try_acquire_lock() {
  # Stage the pid file outside the lock first, then `mv` it in after
  # `mkdir` succeeds. Without this, there's a window between mkdir and
  # `echo $$ >` where a contending poll sees an empty pid file and
  # races to steal a freshly-acquired (still healthy) lock.
  local tmp_pid="${LOCK}.pid.$$"
  echo $$ > "$tmp_pid" 2>/dev/null || return 1
  if mkdir "$LOCK" 2>/dev/null; then
    mv -f "$tmp_pid" "$LOCK_PID" 2>/dev/null
    return 0
  fi
  rm -f "$tmp_pid" 2>/dev/null
  # Lock contended. Inspect the holder.
  local owner age
  owner="$(cat "$LOCK_PID" 2>/dev/null || echo "")"
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if [[ -z "$owner" ]]; then
    # Empty pid could mean (a) leaked lock from a SIGKILL'd owner, or
    # (b) a contender that *just* won mkdir and hasn't moved its pid
    # in yet. Re-read after a short grace; if still empty, treat as
    # leaked.
    sleep 0.2
    owner="$(cat "$LOCK_PID" 2>/dev/null || echo "")"
  fi
  if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then
    # Owner missing or dead → leaked lock, steal it.
    rm -rf "$LOCK" 2>/dev/null
  elif (( age > LOCK_STALE_AFTER )); then
    # Owner alive but holding too long → assume hung, steal it.
    rm -rf "$LOCK" 2>/dev/null
  else
    return 1  # active healthy owner; back off
  fi
  echo $$ > "$tmp_pid" 2>/dev/null || return 1
  if mkdir "$LOCK" 2>/dev/null; then
    mv -f "$tmp_pid" "$LOCK_PID" 2>/dev/null
    return 0
  fi
  rm -f "$tmp_pid" 2>/dev/null
  return 1
}
try_acquire_lock || exit 0
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM HUP

mkdir -p "$(dirname "$HISTORY")"

# Ad detection. Most platform ads (Spotify Free, Apple Music free tier
# preview, etc.) register through MediaRemote with brand names as both
# title and artist, with empty artist, or with explicit ad copy in the
# title. Filter these out so they don't pollute recent[] or history.
is_ad() {
  local t="${1:-}" a="${2:-}"
  [[ -z "$t" || -z "$a" ]] && { echo true; return; }
  # Use sed for whitespace trimming, not xargs — xargs does shell-style
  # quote parsing and chokes on apostrophes ("Lenny's Podcast" → empty
  # output + 'unterminated quote' error to stderr).
  local lt la
  lt="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  la="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  # title and artist identical → brand-only entry
  [[ "$lt" == "$la" ]] && { echo true; return; }
  # explicit ad keywords in title
  case "$lt" in
    *advertisement*|*ad-free*|*"ads-free"*|*"ad free"*|"shop now"*|"get more"*|*"click here"*|*"save now"*|*"learn more"*|*"sign up"*|*"call now"*|*"book now"*|*"limited time"*) echo true; return ;;
  esac
  # known ad-platform / non-music "artists". openai = the ChatGPT site's
  # 30s media element MediaRemote misreports as a track (artist=OpenAI);
  # real podcasts about OpenAI carry the show name as artist, so they pass.
  case "$la" in
    spotify|topsify|"spotify – advertisement"|openai) echo true; return ;;
  esac
  echo false
}

# Pull seven fields, one per line, in this exact order.
# clientBundleIdentifier tells us which app owns the current MediaRemote
# session (com.spotify.client, com.google.Chrome, com.apple.Safari, …).
# We bake it into the cache so downstream scripts can gate source-specific
# enrichment (e.g. Spotify Web API state only when Spotify is the source).
RAW="$(nowplaying-cli get title artist album duration elapsedTime playbackRate clientBundleIdentifier 2>/dev/null || true)"
TITLE="$(printf '%s\n' "$RAW" | sed -n '1p')"
ARTIST="$(printf '%s\n' "$RAW" | sed -n '2p')"
ALBUM="$(printf '%s\n' "$RAW" | sed -n '3p')"
DURATION_RAW="$(printf '%s\n' "$RAW" | sed -n '4p')"
ELAPSED_RAW="$(printf '%s\n' "$RAW" | sed -n '5p')"
RATE_RAW="$(printf '%s\n' "$RAW" | sed -n '6p')"
BUNDLE_ID="$(printf '%s\n' "$RAW" | sed -n '7p')"
[[ "$BUNDLE_ID" == "null" ]] && BUNDLE_ID=""

# Coerce numeric fields safely. nowplaying-cli prints empty/null for missing.
to_num() {
  local v="${1:-0}"
  [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && printf '%.0f' "$v" || echo 0
}
DURATION="$(to_num "$DURATION_RAW")"
ELAPSED="$(to_num "$ELAPSED_RAW")"
RATE="$(to_num "$RATE_RAW")"

# App allowlist — only record media sessions from known media sources.
# MediaRemote surfaces now-playing from any app; games/Figma/other apps
# are dropped. Note this list is intentionally broad (players + browsers
# + video apps), so non-music media (VLC films, Apple TV+, podcasts) will
# also be logged — the skip filter (heard-time > 0) is what suppresses
# the paused-ghost noise, not this gate.
#   com.spotify.client       Spotify desktop (also drives the liked/state API)
#   com.apple.Music          Apple Music
#   com.tencent.QQMusicMac   QQ Music (verified on this machine)
#   com.google.Chrome        Chrome (any tab, incl. YouTube Music)
#   com.apple.Safari         Safari
#   org.mozilla.firefox      Firefox
#   org.videolan.vlc         VLC
#   com.apple.TV             Apple TV+
#   com.apple.podcasts       Podcasts
#   com.colliderli.iina      IINA
#   company.thebrowser.Browser  Arc
# TODO netease: add once installed and its real bundle id is verified.
ALLOWED_BUNDLES="com.spotify.client com.apple.Music com.tencent.QQMusicMac com.google.Chrome com.apple.Safari org.mozilla.firefox org.videolan.vlc com.apple.TV com.apple.podcasts com.colliderli.iina company.thebrowser.Browser"
_allowed=false
for _b in $ALLOWED_BUNDLES; do
  [[ "$BUNDLE_ID" == "$_b" ]] && { _allowed=true; break; }
done
[[ "$_allowed" == "true" ]] || exit 0

# Nothing playing → leave the cache untouched (preserves "vibe drift" of last song).
if [[ -z "$TITLE" || "$TITLE" == "null" ]]; then
  exit 0
fi

NOW="$(date +%s)"
TRACK_KEY="${TITLE}::${ARTIST}"
# Local wall-clock time with an explicit offset (e.g. 2026-09-01T11:24+08:00)
# so history reads as the hour you actually listened AND stays unambiguous
# when shards from machines in different timezones are merged. BSD date has
# no %:z, so insert the colon into %z (+0800 → +08:00) by hand.
ISO_NOW="$(date +%Y-%m-%dT%H:%M%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"

PREV_TRACK_KEY=""
PREV_LOGGED="false"
PREV_TITLE=""
PREV_ARTIST=""
PREV_RECENT="[]"
PREV_PLAYED=0
PREV_POSITION=0
PREV_TICK_AT="$NOW"
LAST_SKIP_LOGGED=""
if [[ -s "$CACHE" ]] && jq -e . "$CACHE" >/dev/null 2>&1; then
  PREV_TRACK_KEY="$(jq -r '.trackKey // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_LOGGED="$(jq -r '.loggedToHistory // false' "$CACHE" 2>/dev/null || echo "false")"
  PREV_TITLE="$(jq -r '.title // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_ARTIST="$(jq -r '.artist // ""' "$CACHE" 2>/dev/null || echo "")"
  PREV_RECENT="$(jq -c '.recent // []' "$CACHE" 2>/dev/null || echo "[]")"
  PREV_PLAYED="$(jq -r '.playbackElapsed // 0' "$CACHE" 2>/dev/null || echo 0)"
  PREV_POSITION="$(jq -r '.playbackPosition // 0' "$CACHE" 2>/dev/null || echo 0)"
  PREV_TICK_AT="$(jq -r '.lastTickAt // 0' "$CACHE" 2>/dev/null || echo "$NOW")"
  # Identity of the last skip line we already appended, so focus churn
  # (MediaRemote handing playback back and forth) can't rewrite it every
  # poll. Format: "<trackKey>@<ISO minute>".
  LAST_SKIP_LOGGED="$(jq -r '.lastSkipLogged // ""' "$CACHE" 2>/dev/null || echo "")"
fi

write_cache() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  mv -f "$tmp" "$CACHE"
}

if [[ "$TRACK_KEY" != "$PREV_TRACK_KEY" ]]; then
  # ── New song ─────────────────────────────────────────────────────────
  # Push previous track onto the front of the recent buffer (cap at
  # RECENT_LIMIT) — but skip ads to keep drift signal clean.
  PREV_WAS_SKIP=false
  if [[ -n "$PREV_TRACK_KEY" && "$(is_ad "$PREV_TITLE" "$PREV_ARTIST")" == "false" ]]; then
    # A song listened to < SKIP_THRESHOLD seconds counts as a skip —
    # but only if we actually observed it playing. A track with 0 heard
    # seconds was never really played: it's a paused-ghost handoff (e.g.
    # closing a browser tab hands MediaRemote focus back to a paused
    # Spotify session), not a user skip. Requiring PREV_PLAYED > 0 both
    # kills those ghosts and drops the noisy `skipped 0s` line, while
    # still logging genuine quick-skips (which always accrue a second or
    # two of rate==1 playtime before the next track change).
    (( PREV_PLAYED > 0 && PREV_PLAYED < SKIP_THRESHOLD )) && PREV_WAS_SKIP=true
    NEW_RECENT="$(jq -c \
      --arg t "$PREV_TITLE" \
      --arg a "$PREV_ARTIST" \
      --arg al "$( jq -r '.album // ""' "$CACHE" 2>/dev/null )" \
      --argjson ts "$NOW" \
      --argjson skipped "$PREV_WAS_SKIP" \
      "[{title:\$t, artist:\$a, album:\$al, ts:\$ts, skipped:\$skipped}] + . | .[0:${RECENT_LIMIT}]" \
      <<<"$PREV_RECENT")"

    # Log skipped tracks to history (the 30s-threshold path won't catch
    # them since they never crossed it). Captures interaction signal
    # that was previously only visible in the in-memory recent[] buffer.
    #
    # Guard against focus churn: when MediaRemote hands playback back and
    # forth, TRACK_KEY != PREV_TRACK_KEY keeps firing and would append the
    # SAME skip line on every poll (all sharing one minute-precision ISO
    # timestamp). Skip the write if we already logged this exact
    # (trackKey, minute) skip. This mark rides in the cache below.
    SKIP_MARK_NOW="${PREV_TRACK_KEY}@${ISO_NOW}"
    if [[ "$PREV_WAS_SKIP" == "true" && "$PREV_LOGGED" == "false" \
          && "$SKIP_MARK_NOW" != "$LAST_SKIP_LOGGED" ]]; then
      printf '%s\n' "- ${ISO_NOW} — ${PREV_TITLE} · ${PREV_ARTIST} · skipped ${PREV_PLAYED}s" >> "$HISTORY"
      LAST_SKIP_LOGGED="$SKIP_MARK_NOW"
    fi
  else
    NEW_RECENT="$PREV_RECENT"
  fi

  # Cover artwork: ALWAYS clear the file first so a song without
  # artwork doesn't keep showing the previous song's cover. Then try
  # the dump. coverAvailable reflects whether THIS fetch produced data.
  rm -f "$COVER"
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

  # Genre enrichment (iTunes + Spotify). Bounded by internal timeouts.
  ENRICH_JSON="$(bash "$SCRIPT_DIR/music-enrich.sh" "$ARTIST" "$TITLE" 2>/dev/null || echo '{}')"
  [[ -z "$ENRICH_JSON" ]] && ENRICH_JSON='{}'

  # Live Spotify player state: shuffle/repeat/context/device + Liked.
  # Returns {} when nothing-Spotify is playing (e.g. Apple Music, browser
  # tab via Media Session) so it's safe to call unconditionally — merge
  # becomes a no-op in that case. We pass the MediaRemote bundle id so
  # the state script can short-circuit: /me/player returns Spotify's last
  # server-side session even after the user swaps to YouTube, leaking a
  # stale liked/context/shuffle onto a totally different track.
  SPOTIFY_JSON="$(MUSIC_SOURCE_BUNDLE_ID="$BUNDLE_ID" MUSIC_CURRENT_TITLE="$TITLE" MUSIC_CURRENT_ARTIST="$ARTIST" bash "$SCRIPT_DIR/music-player-state.sh" 2>/dev/null || echo '{}')"
  [[ -z "$SPOTIFY_JSON" ]] && SPOTIFY_JSON='{}'

  # Played time starts at 0: even if the player begins mid-track (e.g.
  # the user joined a song already in progress), we only count what
  # WE actually observed. Player position starts at the player's value.
  jq -n \
    --arg title "$TITLE" \
    --arg artist "$ARTIST" \
    --arg album "$ALBUM" \
    --arg trackKey "$TRACK_KEY" \
    --argjson duration "$DURATION" \
    --argjson initialElapsed "$ELAPSED" \
    --argjson playbackElapsed 0 \
    --argjson playbackPosition "$ELAPSED" \
    --argjson lastTickAt "$NOW" \
    --argjson firstSeenAtUnix "$NOW" \
    --argjson playbackRate "$RATE" \
    --argjson recent "$NEW_RECENT" \
    --argjson coverAvailable "$COVER_AVAILABLE" \
    --argjson enrich "$ENRICH_JSON" \
    --argjson spotify "$SPOTIFY_JSON" \
    --arg startedAt "$ISO_NOW" \
    --arg bundleId "$BUNDLE_ID" \
    --arg lastSkipLogged "$LAST_SKIP_LOGGED" \
    '{title:$title, artist:$artist, album:$album, trackKey:$trackKey,
      duration:$duration, initialElapsed:$initialElapsed,
      playbackElapsed:$playbackElapsed, playbackPosition:$playbackPosition,
      lastTickAt:$lastTickAt, firstSeenAtUnix:$firstSeenAtUnix,
      playbackRate:$playbackRate, recent:$recent,
      coverAvailable:$coverAvailable, coverShownToHook:false,
      startedAt:$startedAt, loggedToHistory:false,
      lastSkipLogged:$lastSkipLogged,
      source:{bundleId:$bundleId}}
      + $enrich + $spotify' | write_cache

  # ── Behavioral signals ─────────────────────────────────────────────
  # Derive listening mode from the recent buffer. Computed once on song
  # change, then baked into the cache for the hook to read.
  BEHAVIOR="$(ENRICH_TITLE="$TITLE" ENRICH_ARTIST="$ARTIST" ENRICH_ALBUM="$ALBUM" python3 -c '
import json, os, sys

title = os.environ.get("ENRICH_TITLE", "")
artist = os.environ.get("ENRICH_ARTIST", "")
album = os.environ.get("ENRICH_ALBUM", "")

try:
    with open("/tmp/music-current.json") as f:
        cache = json.load(f)
except Exception:
    sys.exit(0)

recent = cache.get("recent", [])

# Count skips
skips = sum(1 for r in recent if r.get("skipped"))

# Count consecutive repeats of current song
repeats = sum(1 for r in recent if r.get("title") == title and r.get("artist") == artist) + 1

# Count same-album run in last 5
album_run = 0
if album:
    album_run = sum(1 for r in recent[:5] if r.get("album") == album) + 1

# Derive mode
if repeats >= 2:
    mode = "on-repeat"
elif skips >= 3:
    mode = "restless"
elif album_run >= 3:
    mode = "deep-listening"
else:
    mode = "flowing"

cache["recentSkips"] = skips
cache["consecutiveRepeats"] = repeats
cache["sameAlbumRun"] = album_run
cache["listeningMode"] = mode

print(json.dumps(cache))
' 2>/dev/null)" || true
  if [[ -n "$BEHAVIOR" ]]; then
    printf '%s' "$BEHAVIOR" | write_cache
  fi

else
  # ── Same song ────────────────────────────────────────────────────────
  # Two independent counters:
  #   playbackElapsed = SECONDS HEARD (used for the 30s history threshold).
  #     Only ever += DELTA when rate=1. Never set from player position;
  #     a seek is not "listening time".
  #   playbackPosition = WHERE IN THE TRACK the player is (used for the
  #     statusline countdown). Trusts player's elapsed when reported,
  #     interpolates otherwise.
  DELTA=$(( NOW - PREV_TICK_AT ))
  if (( DELTA < 0 )); then DELTA=0; fi
  # Cap DELTA to MAX_DELTA. The daemon polls every 2s, so a healthy
  # gap is ~2-4s. Anything bigger is a wake-from-sleep, dropped network,
  # or stuck script — counting that whole gap as "heard" or "advanced
  # in track" inflates playbackElapsed and pushes playbackPosition past
  # the song length, producing a -0:00 statusline. Clamp it.
  MAX_DELTA=10
  if (( DELTA > MAX_DELTA )); then
    DELTA=$MAX_DELTA
  fi

  if (( RATE == 1 )); then
    NEW_PLAYED=$(( PREV_PLAYED + DELTA ))
  else
    NEW_PLAYED=$PREV_PLAYED
  fi

  if (( ELAPSED > 0 )); then
    NEW_POSITION=$ELAPSED
  elif (( RATE == 1 )); then
    NEW_POSITION=$(( PREV_POSITION + DELTA ))
  else
    NEW_POSITION=$PREV_POSITION
  fi
  # Clamp position at duration. Before, we'd reset to ELAPSED (often 0
  # when the player doesn't broadcast position) — that made the
  # countdown loop endlessly when the actual track had ended but the
  # player didn't update its rate. Now we hold at duration so the
  # statusline can detect "ended" and stop pretending.
  if (( DURATION > 0 && NEW_POSITION > DURATION )); then
    NEW_POSITION=$DURATION
  fi

  jq \
    --argjson playbackElapsed "$NEW_PLAYED" \
    --argjson playbackPosition "$NEW_POSITION" \
    --argjson lastTickAt "$NOW" \
    --argjson playbackRate "$RATE" \
    '.playbackElapsed = $playbackElapsed
     | .playbackPosition = $playbackPosition
     | .lastTickAt = $lastTickAt
     | .playbackRate = $playbackRate' \
    "$CACHE" | write_cache

  # First crossing of the skip threshold (using actual heard time, not
  # player position — so seeking past 30s doesn't auto-log a track the
  # user never actually listened to). Skip ads.
  if [[ "$PREV_LOGGED" == "false" && "$NEW_PLAYED" -ge "$SKIP_THRESHOLD" \
        && "$(is_ad "$TITLE" "$ARTIST")" == "false" ]]; then
    HIST_GENRE="$(jq -r '
      if (.genres // []) | length > 0 then " [" + (.genres | join(", ")) + "]"
      elif (.genre // "") != "" then " [" + .genre + "]"
      else ""
      end
    ' "$CACHE" 2>/dev/null)"
    REPEAT_MARK=""
    REPEAT_COUNT="$(jq -r '.consecutiveRepeats // 1' "$CACHE" 2>/dev/null)"
    (( REPEAT_COUNT >= 2 )) && REPEAT_MARK=" · repeat ${REPEAT_COUNT}x"
    LIKED_MARK=""
    [[ "$(jq -r '.spotify.liked // false' "$CACHE" 2>/dev/null)" == "true" ]] && LIKED_MARK=" ❤"
    printf '%s\n' "- ${ISO_NOW} — ${TITLE} · ${ARTIST}${HIST_GENRE}${REPEAT_MARK}${LIKED_MARK}" >> "$HISTORY"
    jq '.loggedToHistory = true' "$CACHE" | write_cache
  fi
fi
