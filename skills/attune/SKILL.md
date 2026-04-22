---
name: attune
description: Make Claude session-aware of the music the user is currently listening to. Reads now-playing metadata + lyrics + recent track history from macOS MediaRemote and injects them as context every turn, letting Claude naturally mirror the user's vibe (or ignore it for transactional asks). Use this skill when the user wants Claude's tone to follow their music, when they ask "what am I listening to", or to install / uninstall / explain the attune mechanism.
---

# Attune — Music-Synced Session Vibe

A Claude Code skill that turns the user's current music into a session-wide signal. No presets, no schema. The mechanism is intentionally minimal: poll, cache, inject — let Claude derive everything.

## What it does

- Detects the currently playing track on macOS (any player: Spotify, Apple Music, QQ Music, NetEase, browser tabs that use Media Session API…).
- On every song change, fetches up to four lines of lyrics from [lrclib](https://lrclib.net/) and updates a cache at `/tmp/vibe-current.json`.
- Logs each track to `~/.cache/vibe/play_history.md` once it has been listened to for ≥ 30 seconds (skips don't count).
- Renders an optional statusline row: `🎧 <title>  -<remaining>`.
- On every `UserPromptSubmit`, injects a `<now-playing>` block (track + lyrics + last 10 tracks) into the next assistant turn.

## How Claude should use the injected `<now-playing>` block

The block is **signal, not instruction**. Claude reads it and decides per-task:

- Creative / open-ended / mood-laden requests → mirror the music's pace, tone, and density. Slow ambient track → terse, spacious responses. Energetic track → tighter, punchier delivery.
- Transactional / debugging / "fix the npm error" requests → ignore the vibe; correctness wins.
- "How am I doing today?" / music-adjacent questions → it's fair game to reference what the user is actually listening to.

Never quote the `<now-playing>` block back at the user verbatim. Don't perform the vibe — just be it.

## Install

```bash
bash /Users/yuuue/Documents/vibes/skills/attune/install.sh
```

The installer:
1. Verifies `nowplaying-cli`, `jq`, `curl`, `python3` are on PATH.
2. Appends a UserPromptSubmit hook entry to `~/.claude/settings.json` (does not touch existing hooks).
3. Writes `~/.claude/statuslines/attune.sh` as a new statusline-vibe option.
4. Appends a one-line pointer to `~/.claude/CLAUDE.md` so the play history is discoverable from any cwd.
5. Ensures `~/.cache/vibe/` exists.

After install, the **hook is active for new Claude Code sessions**. To enable the 🎧 statusline this session:

```bash
echo attune > "/tmp/.claude-session-$PPID/vibe"
```

To make it the default for new sessions, edit `~/.claude/statusline-command.sh` and change the fallback from `pomodoro` to `attune`.

## Uninstall

```bash
bash /Users/yuuue/Documents/vibes/skills/attune/uninstall.sh
```

Removes the hook entry, the statusline option, and the CLAUDE.md pointer. Leaves the play history file intact.

## Files

| Path | Purpose |
|---|---|
| `bin/vibe-poll.sh` | Sensor: reads MediaRemote, diffs cache, fetches lyrics, rolls recent buffer, logs history. |
| `bin/vibe-statusline.sh` | Statusline renderer; calls `vibe-poll.sh` first so polling and display share a tick. |
| `bin/vibe-hook.sh` | UserPromptSubmit hook; pure cache reader, outputs `additionalContext`. |
| `install.sh` / `uninstall.sh` | Idempotent setup / teardown. |
| `/tmp/vibe-current.json` | Source of truth (ephemeral). |
| `~/.cache/vibe/play_history.md` | Append-only listening log (persistent). |

## Phase 1 boundaries

| Out of scope | Reason |
|---|---|
| Linux / Windows | `nowplaying-cli` is macOS-only. |
| Cover image injection | `additionalContext` is text; multimodal injection needs more work. |
| Chinese / Japanese / Korean lyrics | lrclib coverage is mostly Western; NetEase fallback is Phase 1.1. |
| Pre-derived "vibe brief" / schema | We trust Claude to interpret the raw signal. |
| Auto playlist generation | Different direction; handled by `ncm-cli` flows separately. |
