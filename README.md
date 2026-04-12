# vibing-supply

Music-synced session vibe for [Claude Code](https://www.anthropic.com/claude-code).

Reads what you're playing in any macOS music app (Spotify, Apple Music, QQ Music, NetEase, browser tabs that use Media Session API) and injects the metadata + lyrics + recent track history into Claude's context every turn — so Claude can naturally mirror your mood.

The signal is intentionally minimal: nothing tells Claude "be terse" or "use emoji". It just sees what you're listening to and decides per-task whether the music is relevant (creative / open-ended asks) or to be ignored (debugging, transactional work).

## Install

```bash
npx vibing-supply install
```

Or directly from GitHub:

```bash
npx github:Yukioa2z/vibes install
```

The installer:

1. Verifies dependencies: `nowplaying-cli`, `jq`, `curl`, `python3` (all on Homebrew)
2. Appends a `UserPromptSubmit` hook to `~/.claude/settings.json` (existing hooks are preserved)
3. Adds a `music` statusline option at `~/.claude/statuslines/music.sh` that composes with your existing base vibe
4. Installs a `launchd KeepAlive` daemon at `~/Library/LaunchAgents/supply.music.poll.plist` that polls every 2s
5. Adds a play-history pointer to `~/.claude/CLAUDE.md` so the log is discoverable from any cwd

After install, the hook is active in any **new** Claude Code session.

To make `🎧` your default statusline, edit `~/.claude/statusline-command.sh` and change the fallback from `pomodoro` to `music`.

## Uninstall

```bash
npx vibing-supply uninstall
```

Removes the hook, statusline option, daemon, and CLAUDE.md pointer. Leaves `~/.cache/music/play_history.md` intact.

## What gets injected

Every `UserPromptSubmit` adds a context block like:

```
<now-playing>
"Holocene" — Bon Iver (album: Bon Iver, Bon Iver, 2011)
Genre: Indie / Folk
Lyrics:
  Someway, baby, it's part of me, apart from me
  And at once, I knew, I was not magnificent
  But I could see for miles, miles, miles
  ...

Recent drift (last 10):
  [-1] Live Love love · Shin-Ski
  [-2] Your Eyes · Monocule
  ...

(Cover image at /tmp/music-cover.jpg — Read for visual signal. First mention only this turn.)
(Full play history: ~/.cache/music/play_history.md)
</now-playing>
```

Songs listened to for ≥ 30 seconds are appended to the persistent play history at `~/.cache/music/play_history.md`. Ads are filtered.

## Capability tiers

| Tier | Setup | What works |
|---|---|---|
| **0 (default)** | `npx vibing-supply install` | nowplaying-cli sensor: title/artist/album, lyrics, cover, iTunes genre, skip/repeat detection, `<now-playing>` injection, statusline |
| **1 (Spotify Free)** | + register your own Spotify app + run setup | tier 0 + Liked detection, recently-played backfill, top tracks/artists, finer Spotify genres, live shuffle/repeat/context |
| **2 (Spotify Premium)** | tier 1 with a Premium account | tier 1 + playback control (play/pause/skip/save/queue/transfer/etc.) |

Run `bash skills/music/bin/music-capabilities.sh` to see what tier this install is on.

## Optional: Spotify (tiers 1 & 2)

vibing-supply does **not** ship a Spotify app — you bring your own. Free, takes a minute:

1. Register an app at <https://developer.spotify.com/dashboard>
   - Redirect URI: `http://127.0.0.1:8888/callback` (must be loopback IP, not `localhost`)
   - APIs used: check **Web API**
2. Copy the Client ID, then:

```bash
npx vibing-supply spotify-setup <client_id>           # one-time OAuth
bash skills/music/bin/music-history-sync.sh all       # seed Taste/Backfill/Liked cache
bash skills/music/bin/music-capabilities.sh           # confirm what unlocked
```

Tokens land at `~/.config/music/spotify.json` (gitignored).

Free accounts → tier 1. Premium → tier 2 (control commands work). Free + control attempt → `403 PREMIUM_REQUIRED` (Spotify rule, not a vibing-supply limit).

## Requirements

- macOS (uses `nowplaying-cli` + MediaRemote framework)
- Node ≥ 14
- `nowplaying-cli` (`brew install nowplaying-cli`)
- `jq`, `curl`, `python3` (system / Homebrew)

## How it works

See [`skills/music/SKILL.md`](skills/music/SKILL.md) for architecture details.

## License

MIT
