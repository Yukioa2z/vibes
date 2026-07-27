#!/usr/bin/env bash
# music-spotify-auth.sh — sourced helper.
#
# Provides:
#   spotify_get_token [config_path]
#     Echoes a valid access_token. Refreshes in-place if expired.
#     Returns 1 (and stays silent) if no config or refresh fails.
#
# Refresh writes back to the config file atomically so subsequent calls
# in the same process — and other processes — see the new token.
#
# A refresh that fails with invalid_grant is terminal: the authorization
# is gone and no amount of retrying brings it back. That case writes
# AUTH_ERROR so the statusline can surface it — a silent return 1 here
# is indistinguishable from "user is playing YouTube", which is how a
# revoked token once went unnoticed for 80 days.
#
# Refreshes are serialized across processes. Five callers (poll loop,
# statusline, hook, control, history-sync) can wake at once on an expired
# token and each fire its own POST; Spotify rate-limits per client_id,
# and PKCE apps have a public client_id, so that quota is the only thing
# standing between a burst and an hours-long ban. The winner writes the
# new token; everyone else re-reads the file and uses it.

SPOTIFY_CONFIG_DEFAULT="$HOME/.config/music/spotify.json"
SPOTIFY_AUTH_ERROR="$HOME/.cache/music/auth-error.txt"
SPOTIFY_REFRESH_LOCK="${TMPDIR:-/tmp}/music-spotify-refresh.lock"

# Reads the cached token, printing it only if it's good for >30 more
# seconds. Returns 1 when a refresh is needed.
_spotify_cached_token() {
  local config="$1" at ea
  at="$(jq -r '.access_token // ""' "$config" 2>/dev/null)"
  ea="$(jq -r '.expires_at // 0'    "$config" 2>/dev/null)"
  # Refresh slightly before expiry to dodge in-flight 401s.
  if (( $(date +%s) < ea - 30 )) && [[ -n "$at" ]]; then
    printf '%s' "$at"
    return 0
  fi
  return 1
}

spotify_get_token() {
  local config="${1:-$SPOTIFY_CONFIG_DEFAULT}"
  [[ -f "$config" ]] || return 1

  _spotify_cached_token "$config" && return 0

  # Contend for the right to refresh. mkdir is POSIX-atomic, matching the
  # lock style in music-poll.sh (no flock on stock macOS).
  local lock_held=false i
  for (( i = 0; i < 50; i++ )); do
    if mkdir "$SPOTIFY_REFRESH_LOCK" 2>/dev/null; then
      lock_held=true
      break
    fi
    # Someone else is refreshing. Give them a moment, then check whether
    # their result landed — that's the common path, not an error.
    sleep 0.1
    _spotify_cached_token "$config" && return 0
    # Reclaim a lock leaked by a killed holder (the daemon SIGKILLs
    # wedged polls, so this does happen).
    if [[ -d "$SPOTIFY_REFRESH_LOCK" ]]; then
      local age
      age=$(( $(date +%s) - $(stat -f %m "$SPOTIFY_REFRESH_LOCK" 2>/dev/null || date +%s) ))
      (( age > 30 )) && rmdir "$SPOTIFY_REFRESH_LOCK" 2>/dev/null
    fi
  done
  # Lock never came free: fall through unlocked rather than fail outright.
  # A stray extra POST beats losing playback state entirely.

  # Re-check under the lock: whoever we queued behind may have just
  # refreshed, in which case we must not spend another request.
  if [[ "$lock_held" == true ]] && _spotify_cached_token "$config"; then
    rmdir "$SPOTIFY_REFRESH_LOCK" 2>/dev/null
    return 0
  fi

  local at now
  now="$(date +%s)"

  # Every exit from here on must drop the lock, or one killed caller
  # wedges refreshes for everyone until the staleness reclaim kicks in.
  _spotify_unlock() {
    [[ "$lock_held" == true ]] && rmdir "$SPOTIFY_REFRESH_LOCK" 2>/dev/null
    lock_held=false
  }

  local rt ci
  rt="$(jq -r '.refresh_token // ""' "$config" 2>/dev/null)"
  ci="$(jq -r '.client_id // ""'     "$config" 2>/dev/null)"
  if [[ -z "$rt" || -z "$ci" ]]; then
    _spotify_unlock
    return 1
  fi

  # No -f: on 4xx we need the body, which carries the error reason.
  local resp
  resp="$(curl --noproxy '*' -sS --max-time 5 \
    -X POST "https://accounts.spotify.com/api/token" \
    -d "grant_type=refresh_token" \
    -d "refresh_token=$rt" \
    -d "client_id=$ci" 2>/dev/null || echo '{}')"

  at="$(printf '%s' "$resp" | jq -r '.access_token // ""' 2>/dev/null)"
  if [[ -z "$at" ]]; then
    # invalid_grant = authorization revoked or refresh token replayed.
    # Anything else (network, 5xx, timeout) is transient — stay quiet so
    # a flaky connection doesn't nag the user to re-authorize.
    if [[ "$(printf '%s' "$resp" | jq -r '.error // ""' 2>/dev/null)" == "invalid_grant" ]]; then
      local why
      why="$(printf '%s' "$resp" | jq -r '.error_description // "invalid_grant"' 2>/dev/null)"
      mkdir -p "$(dirname "$SPOTIFY_AUTH_ERROR")" 2>/dev/null
      printf '%s · %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$why" > "$SPOTIFY_AUTH_ERROR"
    fi
    _spotify_unlock
    return 1
  fi

  # Recovered — clear any stale revocation notice.
  rm -f "$SPOTIFY_AUTH_ERROR" 2>/dev/null

  local new_rt ein
  new_rt="$(printf '%s' "$resp" | jq -r '.refresh_token // ""')"
  ein="$(  printf '%s' "$resp" | jq -r '.expires_in // 3600')"

  local tmp; tmp="$(mktemp)"
  jq --arg at "$at" \
     --arg rt "${new_rt:-$rt}" \
     --argjson ea "$((now + ein))" \
     '.access_token=$at
      | .refresh_token=(if $rt!="" then $rt else .refresh_token end)
      | .expires_at=$ea' \
     "$config" > "$tmp"
  mv -f "$tmp" "$config"

  _spotify_unlock
  printf '%s' "$at"
}
