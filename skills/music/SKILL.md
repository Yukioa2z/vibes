---
name: music
description: Make Claude session-aware of the music the user is currently listening to. Reads now-playing metadata + lyrics + recent track history from macOS MediaRemote and injects them as context every turn, letting Claude naturally mirror the user's vibe (or ignore it for transactional asks). Use this skill when the user wants Claude's tone to follow their music, when they ask "what am I listening to", or to install / uninstall / explain the music mechanism.
---

# Attune — Music-Synced Session Vibe

A Claude Code skill that turns the user's current music into a session-wide signal. No presets, no schema. The mechanism is intentionally minimal: poll, cache, inject — let Claude derive everything.

## What it does

- Detects the currently playing track on macOS (any player: Spotify, Apple Music, QQ Music, NetEase, browser tabs that use Media Session API…).
- A launchd `KeepAlive` daemon runs `vibe-poll.sh` every 2 seconds, keeping the cache at `/tmp/vibe-current.json` fresh independently of Claude Code activity.
- On every song change, fetches up to four lines of lyrics from [lrclib](https://lrclib.net/) and updates the cache.
- Logs each track to `~/.cache/vibe/play_history.md` once it has been listened to for ≥ 30 seconds (skips don't count).
- Renders an optional statusline row: `🎧 <title>  -<remaining>`, **appended below your existing statusline content** (the `music` vibe composes with whatever base vibe you already use — default `pomodoro`; override with `VIBE_BASE`). Note: Claude Code's statusline only re-renders on events in current versions — when it renders it shows the latest cache, but the countdown does not visibly tick between events.
- On every `UserPromptSubmit`, injects a `<now-playing>` block (track + lyrics + last 10 tracks) into the next assistant turn.

## The `<now-playing>` block

This is the music playing in the room right now. Don't quote it back verbatim.

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

## Files

| Path | Purpose |
|---|---|
| `bin/vibe-poll.sh` | Sensor: reads MediaRemote, diffs cache, fetches lyrics, rolls recent buffer, logs history. |
| `bin/vibe-statusline.sh` | Statusline renderer; calls `vibe-poll.sh` first as a safety refresh. |
| `bin/vibe-hook.sh` | UserPromptSubmit hook; pure cache reader, outputs `additionalContext`. |
| `install.sh` / `uninstall.sh` | Idempotent setup / teardown. |
| `~/Library/Application Support/vibe/poll.sh` | Copy of `vibe-poll.sh` accessible to launchd. |
| `~/Library/Application Support/vibe/daemon.sh` | Long-running loop invoked by launchd; polls every 2s. |
| `~/Library/LaunchAgents/supply.vibe.poll.plist` | launchd `KeepAlive` job that keeps `daemon.sh` running. |
| `/tmp/vibe-current.json` | Source of truth (ephemeral). |
| `~/.cache/vibe/play_history.md` | Append-only listening log (persistent). |

## Phase 1 boundaries

| Out of scope | Reason |
|---|---|
| Linux / Windows | `nowplaying-cli` is macOS-only. |
| Pre-derived "vibe brief" / schema | We trust Claude to interpret the raw signal. |
| Auto playlist generation | Different direction; handled by `ncm-cli` flows separately. |
| Statusline auto-tick | Claude Code's statusline only re-renders on events in current versions. |

## What it now handles (since initial Phase 1)

- **Cover image** — saved to `/tmp/vibe-cover.jpg` on every song change. The hook injects a hint mentioning the path on the **first** turn after a song change; subsequent turns omit the hint to avoid noise. The assistant can `Read` the path to get a multimodal signal (palette, era, aesthetic).
- **CJK lyrics** — when lrclib has no entry, falls back to NetEase's anonymous public mobile API (search → song/lyric). Strips LRC timestamps, ID3 metadata, and credit lines.
- **Pause / seek** — `playbackElapsed` only advances when `playbackRate=1`; pauses freeze the count. If the player reports an `elapsedTime` that disagrees with our local count by > 5s, we treat it as a seek and resync. The 30s history-append threshold uses real played time, not wall time.
