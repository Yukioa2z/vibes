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

SPOTIFY_CONFIG_DEFAULT="$HOME/.config/music/spotify.json"
SPOTIFY_AUTH_ERROR="$HOME/.cache/music/auth-error.txt"

spotify_get_token() {
  local config="${1:-$SPOTIFY_CONFIG_DEFAULT}"
  [[ -f "$config" ]] || return 1

  local at ea now
  at="$(jq -r '.access_token // ""' "$config" 2>/dev/null)"
  ea="$(jq -r '.expires_at // 0'    "$config" 2>/dev/null)"
  now="$(date +%s)"

  # Refresh slightly before expiry to dodge in-flight 401s.
  if (( now < ea - 30 )) && [[ -n "$at" ]]; then
    printf '%s' "$at"
    return 0
  fi

  local rt ci
  rt="$(jq -r '.refresh_token // ""' "$config" 2>/dev/null)"
  ci="$(jq -r '.client_id // ""'     "$config" 2>/dev/null)"
  [[ -z "$rt" || -z "$ci" ]] && return 1

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

  printf '%s' "$at"
}
