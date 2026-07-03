---
name: music
description: Keep Claude aware of the user's music without noise. By default a launchd daemon records every track the user plays into a local listening log (`~/.cache/music/play_history.md`) with skip/repeat/album-run signals, and on each turn refreshes a `<now-playing>` snapshot at `~/.cache/music/now-playing.txt` that Claude reads on demand — nothing is injected into the prompt. With Spotify connected it also builds a Wrapped-style taste profile (top tracks/artists across short/medium/long-term windows) and, on Premium, controls playback (play/pause/skip/volume/queue/save). Use this skill when the user asks "what am I listening to", wants Claude's tone to follow their music, wants their listening trend / taste summary, to control Spotify, or to install / uninstall / explain the music mechanism.
---

# Music — Session-Aware Listening Context

A Claude Code skill that records the user's listening history and, on demand, surfaces what they're playing right now. No presets, no schema. The mechanism is intentionally minimal: poll, cache, log — let Claude derive everything. Nothing is pushed into the prompt; Claude reads the snapshot only when music is relevant.

## Capability tiers

The skill works at three levels; everything past tier 0 is opt-in.

| Tier | Setup | What works |
|---|---|---|
| **0 (default)** | `install.sh` only | nowplaying-cli sensor: title/artist/album, iTunes genre, skip/repeat detection, on-demand `<now-playing>` snapshot file, statusline, persistent history log |
| **1 (Spotify Free)** | + register Spotify app + `music-spotify-setup.py <client_id>` | tier 0 + Liked detection in the snapshot, recently-played backfill, top tracks/artists, finer-grained Spotify genres, live shuffle/repeat/context/device state |
| **2 (Spotify Premium)** | tier 1 with a Premium account | tier 1 + playback control via `music-control.sh` (play/pause/skip/save/queue/transfer/etc.) |

**Run `bash bin/music-capabilities.sh`** any time to detect what tier this install is on and what features are enabled. Snapshot lands at `~/.cache/music/capabilities.json` for other scripts (and Claude) to read.

When suggesting a Spotify-tier feature to the user, check capabilities first instead of attempting and parsing the failure.

## What it does

- Detects the currently playing track on macOS (any player: Spotify, Apple Music, QQ Music, NetEase, browser tabs that use Media Session API…).
- A launchd `KeepAlive` daemon runs `music-poll.sh` every 2 seconds, keeping the cache at `/tmp/music-current.json` fresh independently of Claude Code activity.
- On every song change:
  - Enriches with genre via iTunes Search API (free, no auth) and — at tier ≥1 — Spotify artist genres.
  - At tier ≥1: pulls Spotify live state in one shot — shuffle, repeat, playback context (album/playlist/artist radio), active device, and Liked status (cross-referenced against `~/.cache/music/liked_tracks.json`).
  - Tracks listening behavior: skip detection, repeat counting, album runs.
- Writes to `~/.cache/music/play_history.md`:
  - Every track listened to ≥30s gets a line, with `❤` if Liked and `· repeat Nx` if it's the Nth consecutive listen.
  - Skips (<30s) get a separate `· skipped Ns` line — the interaction signal is preserved.
  - `music-control.sh save` / `unsave` append `> liked X · Y` event lines.
  - Claude appends `> note: ...` lines at meaningful milestones (push, PR, deploy, decision).
- Renders an optional statusline row: `🎧 <title>  -<remaining>`, appended below your existing statusline content.
- On every `UserPromptSubmit`, regenerates a `<now-playing>` block (track + genre + Liked + listening behavior + Spotify context if any + recent drift with skip markers) and writes it to `~/.cache/music/now-playing.txt`. The hook itself returns an empty response — nothing is injected into the prompt. Claude reads the snapshot on demand when music is relevant to the task.

## The `<now-playing>` snapshot

The hook keeps `~/.cache/music/now-playing.txt` fresh on every turn but does NOT inject it. When the user asks "what am I listening to", wants tone matched to their music, or the conversation suggests vibe context might help, `Read` the snapshot. It's a small file with a single `<now-playing>...</now-playing>` block. Don't quote it back verbatim. Match tone and pacing — but suppress entirely for transactional/debugging work.

After a meaningful milestone (push, PR, deploy, major decision), append a one-line `> note: ...` to `~/.cache/music/play_history.md` — what happened, not what's playing. Keep it short.

## Controlling playback (tier 2)

Spotify Premium only. Claude drives the player via `bash bin/music-control.sh <subcommand>`:

| Command | Effect |
|---|---|
| `next` / `prev` | Skip forward / back |
| `pause` / `play` | Toggle playback (`play <uri>` jumps to a track / album / playlist / artist) |
| `seek <ms>` | Jump to position |
| `vol <0-100>` | Set volume |
| `shuffle <on\|off>` | Toggle shuffle |
| `repeat <off\|track\|context>` | Repeat mode |
| `queue <spotify:track:...>` | Add to queue |
| `save` / `unsave` | ❤ / un-❤ the currently playing track (also updates local Liked cache and appends an event line to play history) |
| `devices` | List playback devices (active marked with `*`) |
| `transfer <id\|name>` | Move playback to a different device (name match is case-insensitive substring) |

Each command prints one line on success or a parsed error (e.g. `PREMIUM_REQUIRED`, `NO_ACTIVE_DEVICE`). Tokens auto-refresh.

## Listening history sync (tier ≥1)

`bash bin/music-history-sync.sh <subcommand>` pulls Spotify-derived data into local files:

| Subcommand | Effect |
|---|---|
| `taste` | Refresh **Taste Profile** section: top tracks/artists × short/medium/long term windows |
| `backfill` | Populate **Backfilled History** section once from `recently-played` (≤50 tracks). Skips if section already filled, override with `--force`. |
| `library` | Refresh `~/.cache/music/liked_tracks.json` (used by poll for Liked detection — `/me/tracks/contains` is dead for new Spotify apps so we cache locally). |
| `all` | Run all three. |

The history file at `~/.cache/music/play_history.md` is a single source of truth with three sections bounded by HTML markers:

```
<!-- TASTE_PROFILE_START --> ... <!-- TASTE_PROFILE_END -->
<!-- BACKFILL_START --> ... <!-- BACKFILL_END -->
## Live History
- (event-stream from poll.sh + control.sh + Claude notes)
```

## Install

```bash
bash /Users/yuuue/Documents/vibes/skills/music/install.sh
```

The installer:
1. Verifies `nowplaying-cli`, `jq`, `curl`, `python3` are on PATH.
2. Appends a UserPromptSubmit hook entry to `~/.claude/settings.json` (does not touch existing hooks).
3. Writes `~/.claude/statuslines/music.sh` as a new statusline-vibe option.
4. Copies `music-poll.sh` + helpers (`music-enrich.sh`, `music-spotify-auth.sh`, `music-player-state.sh`) into `~/Library/Application Support/music/` (launchd cannot read scripts under `~/Documents/` due to TCC) and installs `~/Library/LaunchAgents/supply.music.poll.plist`, then `launchctl load`s it.
5. Appends a one-line pointer to `~/.claude/CLAUDE.md` so the play history is discoverable from any cwd.
6. Ensures `~/.cache/music/` exists.

After install, the **hook is active for new Claude Code sessions** and the daemon is already polling. To make 🎧 the default statusline, edit `~/.claude/statusline-command.sh` and change the fallback from `pomodoro` to `music`.

## Uninstall

```bash
bash /Users/yuuue/Documents/vibes/skills/music/uninstall.sh
```

Removes the hook entry, the statusline option, the daemon, and the CLAUDE.md pointer. Leaves the play history file intact.

## Spotify setup (optional — unlocks tiers 1 & 2)

vibing-supply does NOT ship a Spotify app — you bring your own. Free, takes a minute.

1. Go to https://developer.spotify.com/dashboard and "Create app"
2. Redirect URI: `http://127.0.0.1:8888/callback` (must be loopback IP, not `localhost`)
3. APIs used: check **Web API**
4. Copy the Client ID

Then:

```bash
python3 bin/music-spotify-setup.py <client_id>     # one-time OAuth
bash    bin/music-history-sync.sh   all            # seed Taste Profile + Backfilled History + Liked cache
bash    bin/music-capabilities.sh                  # confirm what unlocked
```

Tokens auto-refresh and are stored at `~/.config/music/spotify.json` (gitignored).

Free accounts → tier 1 (read-only Spotify enrichment). Premium → tier 2 (adds playback control).

## Files

| Path | Purpose |
|---|---|
| `bin/music-poll.sh` | Core sensor: MediaRemote → cache, enrichment, behavior signals, history. |
| `bin/music-enrich.sh` | Genre enrichment: iTunes Search API + Spotify API. |
| `bin/music-spotify-auth.sh` | Sourced helper: token management with auto-refresh. |
| `bin/music-player-state.sh` | One-shot Spotify state pull (shuffle/repeat/context/device + Liked). |
| `bin/music-hook.sh` | UserPromptSubmit hook; reads cache, writes `<now-playing>` block to `~/.cache/music/now-playing.txt`. Returns empty — never injects into prompt. |
| `bin/music-statusline.sh` | Statusline renderer: `🎧 <title>  -<remaining>`. |
| `bin/music-control.sh` | Playback control via Spotify Web API. |
| `bin/music-history-sync.sh` | Pull taste / backfill / library from Spotify. |
| `bin/music-spotify-setup.py` | One-time Spotify PKCE OAuth flow (BYO client_id). |
| `bin/music-capabilities.sh` | Probe install + Spotify account → derive tier (0/1/2) and per-feature flags. |
| `install.sh` / `uninstall.sh` | Idempotent setup / teardown. |
| `/tmp/music-current.json` | Ephemeral cache (real-time state + behavior + Spotify state). |
| `~/.cache/music/now-playing.txt` | Latest `<now-playing>` snapshot, refreshed on every UserPromptSubmit. Read this on demand. |
| `~/.cache/music/play_history.md` | Persistent listening log (Taste / Backfill / Live sections). |
| `~/.cache/music/liked_tracks.json` | Local snapshot of Spotify Liked Songs for poll lookup. |
| `~/.config/music/spotify.json` | Spotify tokens (created by setup script). |
| `~/.cache/music/capabilities.json` | Tier + feature flags (refreshed by music-capabilities.sh). |

## Boundaries

| Out of scope | Reason |
|---|---|
| Linux / Windows | `nowplaying-cli` is macOS-only. |
| Pre-derived mood labels | Raw signals only — no "you should feel X" instructions. |
| Auto playlist generation | Different product direction. |
| Audio features / analysis / recommendations | Spotify deprecated these endpoints for new apps in Nov 2024. |
