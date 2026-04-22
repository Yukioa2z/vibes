---
name: music
description: Make Claude session-aware of the music the user is currently listening to. Reads now-playing metadata, lyrics, genre, cover art, and listening behavior from macOS MediaRemote and injects them as context every turn. Use this skill when the user wants Claude's tone to follow their music, when they ask "what am I listening to", or to install / uninstall / explain the music mechanism.
---

# Music — Session-Aware Listening Context

A Claude Code skill that turns the user's current music into a session-wide signal. No presets, no schema. The mechanism is intentionally minimal: poll, cache, inject — let Claude derive everything.

## What it does

- Detects the currently playing track on macOS (any player: Spotify, Apple Music, QQ Music, NetEase, browser tabs that use Media Session API…).
- A launchd `KeepAlive` daemon runs `vibe-poll.sh` every 2 seconds, keeping the cache at `/tmp/vibe-current.json` fresh independently of Claude Code activity.
- On every song change:
  - Fetches up to 12 lines of deduplicated lyrics from [lrclib](https://lrclib.net/) (CJK fallback via NetEase API).
  - Saves cover art to `/tmp/vibe-cover.jpg` for multimodal context.
  - Enriches with genre via iTunes Search API (free, no auth) and optionally Spotify API (artist genres, requires one-time OAuth).
  - Tracks listening behavior: skip detection, repeat counting, album runs.
- Logs each track (with genre tag) to `~/.cache/vibe/play_history.md` once listened to for ≥ 30 seconds. Claude appends session notes at milestones.
- Renders an optional statusline row: `🎧 <title>  -<remaining>`, appended below your existing statusline content.
- On every `UserPromptSubmit`, injects a `<now-playing>` block into the next assistant turn: track + genre + lyrics + listening behavior + recent drift with skip markers + cover hint.

## The `<now-playing>` block

This is the music playing in the room right now. Don't quote it back verbatim.

After a meaningful milestone (push, PR, deploy, major decision), append a one-line note to `~/.cache/vibe/play_history.md` — what happened, not what's playing. Keep it short.

## Install

```bash
bash /Users/yuuue/Documents/vibes/skills/music/install.sh
```

The installer:
1. Verifies `nowplaying-cli`, `jq`, `curl`, `python3` are on PATH.
2. Appends a UserPromptSubmit hook entry to `~/.claude/settings.json` (does not touch existing hooks).
3. Writes `~/.claude/statuslines/music.sh` as a new statusline-vibe option.
4. Copies `vibe-poll.sh` into `~/Library/Application Support/vibe/` (launchd cannot read scripts under `~/Documents/` due to TCC) and installs `~/Library/LaunchAgents/supply.vibe.poll.plist`, then `launchctl load`s it.
5. Appends a one-line pointer to `~/.claude/CLAUDE.md` so the play history is discoverable from any cwd.
6. Ensures `~/.cache/vibe/` exists.

After install, the **hook is active for new Claude Code sessions** and the daemon is already polling. To make 🎧 the default statusline, edit `~/.claude/statusline-command.sh` and change the fallback from `pomodoro` to `music`.

## Uninstall

```bash
bash /Users/yuuue/Documents/vibes/skills/music/uninstall.sh
```

Removes the hook entry, the statusline option, and the CLAUDE.md pointer. Leaves the play history file intact.

## Spotify setup (optional)

Adds richer genre tags (e.g. "indie rock, welsh indie" instead of just "Alternative"). One-time setup:

1. Create an app at https://developer.spotify.com/dashboard
2. Add redirect URI: `http://localhost:8888/callback`
3. Run: `python3 bin/vibe-spotify-setup.py <client_id>`

Tokens auto-refresh. No Premium required.

## Files

| Path | Purpose |
|---|---|
| `bin/vibe-poll.sh` | Core sensor: MediaRemote → cache, lyrics, cover, enrichment, behavior signals, history. |
| `bin/vibe-enrich.sh` | Genre enrichment: iTunes Search API + Spotify API (if configured). |
| `bin/vibe-hook.sh` | UserPromptSubmit hook; reads cache, outputs `<now-playing>` block. |
| `bin/vibe-statusline.sh` | Statusline renderer: `🎧 <title>  -<remaining>`. |
| `bin/vibe-spotify-setup.py` | One-time Spotify PKCE OAuth flow. |
| `install.sh` / `uninstall.sh` | Idempotent setup / teardown. |
| `/tmp/vibe-current.json` | Ephemeral cache (real-time state + behavior signals). |
| `~/.cache/vibe/play_history.md` | Persistent listening log with genre tags and session notes. |
| `~/.config/vibe/spotify.json` | Spotify tokens (created by setup script). |

## Boundaries

| Out of scope | Reason |
|---|---|
| Linux / Windows | `nowplaying-cli` is macOS-only. |
| Pre-derived mood labels | Raw signals only — no "you should feel X" instructions. |
| Auto playlist generation | Different product direction. |
| Like/favorite detection | Requires per-app API integration; may add via Spotify later. |
