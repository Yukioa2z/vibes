#!/usr/bin/env bash
# music-capabilities.sh — what can this install actually do?
#
# Probes local config + Spotify account to derive a tier:
#   tier 0  default install — nowplaying-cli only (no Spotify config)
#   tier 1  Spotify Free   — observe + sync history + Liked detection
#   tier 2  Spotify Premium — tier 1 + playback control
#
# Prints a human-readable summary AND writes ~/.cache/music/capabilities.json
# so other scripts (and Claude) can read it without re-probing.
#
# Run this:
#   - after `music-spotify-setup.py` to confirm what unlocked
#   - any time something fails (e.g. PREMIUM_REQUIRED) to see what tier you're on
#   - before suggesting a Spotify-tier-only feature to the user

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=music-spotify-auth.sh
source "$SCRIPT_DIR/music-spotify-auth.sh"

OUT="$HOME/.cache/music/capabilities.json"
mkdir -p "$(dirname "$OUT")"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Tier 0 detection: nowplaying-cli on PATH ───────────────────────
NOWPLAYING_OK=false
command -v nowplaying-cli >/dev/null 2>&1 && NOWPLAYING_OK=true

# ── Tier 1/2 detection: Spotify config + /me probe ─────────────────
SPOTIFY_CONFIGURED=false
PRODUCT="unknown"
ACCOUNT_ID=""
COUNTRY=""
PROBE_ERROR=""

if [[ -f "$HOME/.config/music/spotify.json" ]]; then
  SPOTIFY_CONFIGURED=true
  TOKEN="$(spotify_get_token 2>/dev/null || echo "")"
  if [[ -z "$TOKEN" ]]; then
    PROBE_ERROR="token refresh failed (network down? token revoked?)"
  else
    ME="$(curl --noproxy '*' -fsS --max-time 5 \
      -H "Authorization: Bearer $TOKEN" \
      "https://api.spotify.com/v1/me" 2>/dev/null || echo '{}')"
    PRODUCT="$(  printf '%s' "$ME" | jq -r '.product // "unknown"' 2>/dev/null)"
    ACCOUNT_ID="$(printf '%s' "$ME" | jq -r '.id      // ""'        2>/dev/null)"
    COUNTRY="$(  printf '%s' "$ME" | jq -r '.country  // ""'        2>/dev/null)"
  fi
fi

# ── Derive tier ────────────────────────────────────────────────────
if   ! $NOWPLAYING_OK;        then TIER=-1
elif ! $SPOTIFY_CONFIGURED;   then TIER=0
elif [[ "$PRODUCT" == "premium" ]]; then TIER=2
else                               TIER=1
fi

# ── Per-feature flags (ground truth for any agent making decisions) ─
FEAT_NOWPLAYING=$NOWPLAYING_OK   # title/artist/album, lyrics, cover, skip/repeat
FEAT_LIKED_DETECT=false          # Liked status visible in <now-playing>
FEAT_HISTORY_SYNC=false          # backfill / top-tracks / library cache
FEAT_GENRES_SPOTIFY=false        # artist genres (richer than iTunes alone)
FEAT_PLAYBACK_CONTROL=false      # play/pause/skip/save/etc.

if (( TIER >= 1 )); then
  FEAT_LIKED_DETECT=true
  FEAT_HISTORY_SYNC=true
  FEAT_GENRES_SPOTIFY=true
fi
(( TIER >= 2 )) && FEAT_PLAYBACK_CONTROL=true

# ── Persist ────────────────────────────────────────────────────────
jq -n \
  --argjson nowplaying        "$FEAT_NOWPLAYING" \
  --argjson spotifyConfigured "$SPOTIFY_CONFIGURED" \
  --arg     product           "$PRODUCT" \
  --arg     accountId         "$ACCOUNT_ID" \
  --arg     country           "$COUNTRY" \
  --arg     probeError        "$PROBE_ERROR" \
  --argjson tier              "$TIER" \
  --argjson likedDetect       "$FEAT_LIKED_DETECT" \
  --argjson historySync       "$FEAT_HISTORY_SYNC" \
  --argjson genresSpotify     "$FEAT_GENRES_SPOTIFY" \
  --argjson playbackControl   "$FEAT_PLAYBACK_CONTROL" \
  --arg     checkedAt         "$NOW" \
  '{
     tier: $tier,
     spotify: { configured: $spotifyConfigured, product: $product,
                accountId: $accountId, country: $country,
                probeError: $probeError },
     features: {
       nowplaying:       $nowplaying,
       likedDetect:      $likedDetect,
       historySync:      $historySync,
       genresSpotify:    $genresSpotify,
       playbackControl:  $playbackControl
     },
     checkedAt: $checkedAt
   }' > "$OUT"

# ── Human-readable summary ─────────────────────────────────────────
case "$TIER" in
  -1) echo "TIER -1 — broken install: nowplaying-cli not on PATH" ;;
   0) echo "TIER 0 — nowplaying-cli only (no Spotify config)" ;;
   1) echo "TIER 1 — Spotify Free (observe + sync, no playback control)" ;;
   2) echo "TIER 2 — Spotify Premium (full feature set)" ;;
esac

if (( TIER >= 1 )); then
  echo "  account: ${ACCOUNT_ID:-?} (${COUNTRY:-?}) · product=$PRODUCT"
  [[ -n "$PROBE_ERROR" ]] && echo "  warn: $PROBE_ERROR"
fi

echo ""
echo "Available features:"
$FEAT_NOWPLAYING       && echo "  ✓ nowplaying       (title/artist/album, lyrics, cover, skip/repeat)" \
                       || echo "  ✗ nowplaying       (install: brew install nowplaying-cli)"
$FEAT_LIKED_DETECT     && echo "  ✓ liked-detect     (❤ shown in <now-playing>)" \
                       || echo "  ✗ liked-detect     (run: music-spotify-setup.py <client_id>)"
$FEAT_HISTORY_SYNC     && echo "  ✓ history-sync     (taste profile, backfill, library cache)" \
                       || echo "  ✗ history-sync     (run: music-spotify-setup.py <client_id>)"
$FEAT_GENRES_SPOTIFY   && echo "  ✓ genres-spotify   (artist genres, finer-grained than iTunes)" \
                       || echo "  ✗ genres-spotify   (run: music-spotify-setup.py <client_id>)"
$FEAT_PLAYBACK_CONTROL && echo "  ✓ playback-control (play/pause/skip/save/queue/transfer)" \
                       || echo "  ✗ playback-control (needs Spotify Premium)"

echo ""
echo "Capabilities snapshot: $OUT"
