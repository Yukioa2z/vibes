#!/usr/bin/env bash
# music-history-sync.sh — pull Spotify-derived data into local files.
#
# Subcommands:
#   taste     refresh "Taste Profile" section in play_history.md
#             (top tracks/artists × short/medium/long term windows)
#   backfill  populate "Backfilled History" section ONCE from Spotify
#             recently-played (max 50 tracks, 2-month rolling window).
#             Skips if section already has content unless --force.
#   library   refresh ~/.cache/music/liked_tracks.json (full saved-tracks
#             snapshot — used by music-poll.sh to mark Liked status,
#             since /me/tracks/contains is dead for new Spotify apps)
#   all       run all three
#
# History file is single-source-of-truth at ~/.cache/music/play_history.md.
# Sections are bounded by HTML markers so each subcommand can rewrite its
# own section without touching the others.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=music-spotify-auth.sh
source "$SCRIPT_DIR/music-spotify-auth.sh"

HISTORY="$HOME/.cache/music/play_history.md"
LIKED_CACHE="$HOME/.cache/music/liked_tracks.json"

mkdir -p "$(dirname "$HISTORY")"

say()  { printf '\033[36m[sync]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[sync]\033[0m %s\n' "$*" >&2; exit 1; }

# ── ensure file has the three sections in correct order ────────────
init_history_file() {
  local skeleton
  skeleton="$(cat <<'EOF'
<!-- TASTE_PROFILE_START -->
## Taste Profile
*Not yet synced. Run: `bash music-history-sync.sh taste`*
<!-- TASTE_PROFILE_END -->

---

<!-- BACKFILL_START -->
## Backfilled History
*Not yet synced. Run: `bash music-history-sync.sh backfill`*
<!-- BACKFILL_END -->

---

## Live History
*Tracked by music skill — events: plays, skips, repeats, likes, notes*

EOF
)"

  if [[ ! -f "$HISTORY" ]]; then
    printf '%s' "$skeleton" > "$HISTORY"
    say "created $HISTORY"
    return
  fi

  # Migrate: existing pre-rename history has no markers. Wrap it under
  # ## Live History and prepend the empty Taste/Backfill sections.
  if ! grep -q "TASTE_PROFILE_START" "$HISTORY"; then
    local existing; existing="$(cat "$HISTORY")"
    {
      printf '%s\n\n' "$skeleton"
      printf '%s\n' "$existing"
    } > "$HISTORY.tmp"
    mv -f "$HISTORY.tmp" "$HISTORY"
    say "migrated existing history into Live History section"
  fi
}

# ── replace content between markers ─────────────────────────────────
replace_section() {
  local marker_start="$1" marker_end="$2"
  CONTENT_NEW="$3" python3 - "$HISTORY" "$marker_start" "$marker_end" <<'PY'
import sys, os, re
path, ms, me = sys.argv[1], sys.argv[2], sys.argv[3]
new = os.environ["CONTENT_NEW"]
with open(path) as f: t = f.read()
pat = re.compile(
    r"(<!-- " + re.escape(ms) + r" -->\n).*?(\n<!-- " + re.escape(me) + r" -->)",
    re.S,
)
if not pat.search(t):
    sys.exit("section markers not found: " + ms)
out = pat.sub(lambda m: m.group(1) + new + m.group(2), t)
with open(path, "w") as f: f.write(out)
PY
}

# Extract content between markers (without the markers themselves).
get_section() {
  local ms="$1" me="$2"
  python3 - "$HISTORY" "$ms" "$me" <<'PY'
import sys, re
path, ms, me = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f: t = f.read()
except FileNotFoundError:
    sys.exit(0)
m = re.search(
    r"<!-- " + re.escape(ms) + r" -->\n(.*?)\n<!-- " + re.escape(me) + r" -->",
    t, re.S,
)
if m: print(m.group(1), end="")
PY
}

api() {
  local path="$1" token
  token="$(spotify_get_token)" || return 1
  curl --noproxy '*' -fsS --max-time 10 \
    -H "Authorization: Bearer $token" \
    "https://api.spotify.com/v1$path"
}

# ── subcommand: taste ───────────────────────────────────────────────
sync_taste() {
  init_history_file

  local token; token="$(spotify_get_token)" || fail "no Spotify config — run music-spotify-setup.py first"

  say "fetching top tracks/artists × 3 windows"
  local tt_short tt_med tt_long ta_short ta_med ta_long
  tt_short="$(api '/me/top/tracks?limit=10&time_range=short_term'   || echo '{}')"
  tt_med="$(  api '/me/top/tracks?limit=10&time_range=medium_term'  || echo '{}')"
  tt_long="$( api '/me/top/tracks?limit=10&time_range=long_term'    || echo '{}')"
  ta_short="$(api '/me/top/artists?limit=10&time_range=short_term'  || echo '{}')"
  ta_med="$(  api '/me/top/artists?limit=10&time_range=medium_term' || echo '{}')"
  ta_long="$( api '/me/top/artists?limit=10&time_range=long_term'   || echo '{}')"

  local md
  md="$(TT_S="$tt_short" TT_M="$tt_med" TT_L="$tt_long" \
        TA_S="$ta_short" TA_M="$ta_med" TA_L="$ta_long" \
        python3 <<'PY'
import json, os, datetime

def load(env):
    try: return json.loads(os.environ.get(env, "{}"))
    except: return {}

def fmt_tracks(j):
    items = j.get("items") or []
    if not items: return "_(none)_"
    return "\n".join(
        f"{i+1}. {it.get('name','?')} · {', '.join(a.get('name','?') for a in it.get('artists',[]))}"
        for i, it in enumerate(items)
    )

def fmt_artists(j):
    items = j.get("items") or []
    if not items: return "_(none)_"
    return "\n".join(
        f"{i+1}. {it.get('name','?')}"
        + (f" — _{', '.join(it.get('genres',[])[:3])}_" if it.get('genres') else "")
        for i, it in enumerate(items)
    )

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
out = []
out.append("## Taste Profile")
out.append(f"*Refreshed: {now} · pulled from Spotify*\n")
out.append("**Top Tracks · last 4 weeks**")
out.append(fmt_tracks(load("TT_S")) + "\n")
out.append("**Top Tracks · last 6 months**")
out.append(fmt_tracks(load("TT_M")) + "\n")
out.append("**Top Tracks · all time**")
out.append(fmt_tracks(load("TT_L")) + "\n")
out.append("**Top Artists · last 4 weeks**")
out.append(fmt_artists(load("TA_S")) + "\n")
out.append("**Top Artists · last 6 months**")
out.append(fmt_artists(load("TA_M")) + "\n")
out.append("**Top Artists · all time**")
out.append(fmt_artists(load("TA_L")))
print("\n".join(out))
PY
)"

  replace_section TASTE_PROFILE_START TASTE_PROFILE_END "$md"
  say "Taste Profile updated"
}

# ── subcommand: backfill ────────────────────────────────────────────
sync_backfill() {
  init_history_file

  local force=false
  [[ "${1:-}" == "--force" ]] && force=true

  if ! $force; then
    local existing; existing="$(get_section BACKFILL_START BACKFILL_END)"
    # Skip if section has anything beyond the placeholder
    if [[ -n "$existing" && "$existing" != *"Not yet synced"* ]]; then
      say "Backfilled History already populated — skip (use --force to overwrite)"
      return
    fi
  fi

  local token; token="$(spotify_get_token)" || fail "no Spotify config"

  say "fetching recently-played (max 50)"
  local rp; rp="$(api '/me/player/recently-played?limit=50' || echo '{}')"

  local md
  md="$(RP="$rp" python3 <<'PY'
import json, os, datetime
try: data = json.loads(os.environ.get("RP", "{}"))
except: data = {}
items = data.get("items") or []

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
out = ["## Backfilled History",
       f"*Imported: {now} from Spotify recently-played (oldest first, ≤50 tracks)*\n"]

# items are newest-first; reverse so chronological reads top→bottom
for it in reversed(items):
    t = it.get("track") or {}
    played = it.get("played_at", "")
    # Spotify played_at is UTC; store as local wall-clock with an explicit
    # offset (e.g. 2026-09-01T11:24+08:00) to match music-poll.sh.
    try:
        dt = datetime.datetime.fromisoformat(played.replace("Z", "+00:00"))
        ts = dt.astimezone().strftime("%Y-%m-%dT%H:%M%z")
        ts = ts[:-2] + ":" + ts[-2:] if ts[-5] in "+-" else ts
    except Exception:
        ts = played[:16]
    name = t.get("name", "?")
    artists = ", ".join(a.get("name", "?") for a in t.get("artists", []))
    album = (t.get("album") or {}).get("name", "")
    out.append(f"- {ts} — {name} · {artists}" + (f" _(album: {album})_" if album else ""))

if len(out) == 2:
    out.append("_(no recent plays returned)_")
print("\n".join(out))
PY
)"

  replace_section BACKFILL_START BACKFILL_END "$md"
  say "Backfilled History populated"
}

# ── subcommand: library ─────────────────────────────────────────────
sync_library() {
  local token; token="$(spotify_get_token)" || fail "no Spotify config"

  say "fetching saved tracks (paginated, 50 per page)"
  local all_items='[]' next='/me/tracks?limit=50' page=0
  while [[ -n "$next" ]]; do
    page=$((page + 1))
    local resp; resp="$(api "$next" || echo '{}')"
    [[ -z "$resp" || "$resp" == "{}" ]] && break

    local items; items="$(printf '%s' "$resp" | jq -c '[.items[] | {
      id: .track.id,
      name: .track.name,
      artist: ([.track.artists[].name] | join(", ")),
      album: .track.album.name,
      added_at: .added_at
    }]')"

    all_items="$(jq -c -n --argjson a "$all_items" --argjson b "$items" '$a + $b')"

    local next_url; next_url="$(printf '%s' "$resp" | jq -r '.next // ""')"
    if [[ -n "$next_url" ]]; then
      # strip the base, keep path+query
      next="${next_url#https://api.spotify.com/v1}"
    else
      next=""
    fi
  done

  local count; count="$(printf '%s' "$all_items" | jq 'length')"
  printf '%s\n' "$all_items" | jq '.' > "$LIKED_CACHE"
  say "wrote $count saved tracks → $LIKED_CACHE"
}

# ── dispatch ────────────────────────────────────────────────────────
cmd="${1:-all}"; shift || true
case "$cmd" in
  taste)    sync_taste ;;
  backfill) sync_backfill "$@" ;;
  library)  sync_library ;;
  all)      sync_taste; sync_backfill "$@"; sync_library ;;
  -h|--help|help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "unknown subcommand: $cmd" >&2
    echo "usage: $(basename "$0") {taste|backfill|library|all} [--force]" >&2
    exit 2
    ;;
esac
