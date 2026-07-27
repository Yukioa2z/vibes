# vibing-supply

Keeps a local record of what you listen to while you code, for any coding agent to read.

A background daemon picks up whatever's playing in any macOS music app (Spotify, Apple Music, QQ Music, NetEase, browser tabs that use the Media Session API) — title, artist, album, genre — and builds a running play history: what you skipped, what you had on repeat, the albums you sat with. The live state lands in `~/.cache/music/now-playing.txt`; the history in `~/.cache/music/play_history.md`. Both are plain files on disk, so any agent that can read a file can use them — Claude Code is one integration, not a requirement.

Everything stays on your machine. Over time the history reads as taste: habits, favorites, and the mood you've been in lately from how your listening has drifted. It works with any app, and it's best with Spotify — connecting it adds finer signals (liked songs, top tracks/artists over time) plus playback control on Premium.

Ships with a Claude Code skill: a `UserPromptSubmit` hook that refreshes the snapshot each turn (it never injects into the prompt — the agent reads on demand) and a live 🎧 statusline.

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
5. Symlinks slash commands (currently `/vibe`) from `skills/music/commands/*.md` into `~/.claude/commands/`
6. Adds a pointer to `~/.claude/CLAUDE.md` for both the now-playing snapshot and the play history so they're discoverable from any cwd

After install, the hook is active in any **new** Claude Code session — it refreshes the snapshot file every turn but does not inject anything into the prompt.

The hook, statusline, and daemon all run from copies under `~/Library/Application Support/music/`, not from the package directory — `npx` installs live in a content-hashed cache path that changes on every upgrade. Editing the source therefore requires re-running install before the change takes effect.

To make `🎧` your default statusline, edit `~/.claude/statusline-command.sh` and change the fallback from `pomodoro` to `music`.

### Anonymous install count

After `install` completes successfully, the CLI sends one anonymous event to
`vibing.supply`. It contains only a random installation ID, the package version,
and whether the install came from npm or GitHub. It does not send usernames,
paths, listening history, or machine details. The random ID is stored at
`~/.config/vibing-supply/installation-id` so repeat installs can be counted
separately from unique installations.

Set `VIBING_SUPPLY_TELEMETRY=0` to disable this event.

## Uninstall

```bash
npx vibing-supply uninstall
```

Removes the hook, statusline option, daemon, slash command symlinks, and CLAUDE.md pointer. Leaves `~/.cache/music/play_history.md` intact.

## Slash commands

| Command | Effect |
|---|---|
| `/vibe claude` | Opens [Claude FM](https://www.youtube.com/watch?v=AUQKjgKQF7w) — a 24/7 live coding stream — in your default browser |

More to come. Drop new `*.md` files into `skills/music/commands/` and re-run install; they'll be symlinked into `~/.claude/commands/`.

## What gets written each turn

The hook does NOT inject anything into your prompt. On every `UserPromptSubmit` it regenerates `~/.cache/music/now-playing.txt` with a block like:

```
<now-playing>
"Holocene" — Bon Iver · Indie / Folk
Context: playlist (spotify:playlist:...) · shuffle
Drift: Live Love love · Your Eyes · Hela Nokto · Billboard(skip) · ...
</now-playing>
```

Claude reads it on demand — when you ask "what am I listening to", when matching tone to your music makes sense, or when the task is open-ended enough that vibe context might help. For transactional/debugging work, it stays unread.

Songs listened to for ≥ 30 seconds are appended to the persistent play history at `~/.cache/music/play_history.md`. Ads are filtered. Cover art for the current track is at `/tmp/music-cover.jpg`.

## Capability tiers

| Tier | Setup | What works |
|---|---|---|
| **0 (default)** | `npx vibing-supply install` | nowplaying-cli sensor: title/artist/album, cover, iTunes genre, skip/repeat detection, on-demand `<now-playing>` snapshot file, statusline |
| **1 (Spotify Free)** | + register your own Spotify app + run setup | tier 0 + Liked detection, recently-played backfill, top tracks/artists, finer Spotify genres, live shuffle/repeat/context |
| **2 (Spotify Premium)** | tier 1 with a Premium account | tier 1 + playback control (play/pause/skip/save/queue/transfer/etc.) |

Run `npx vibing-supply capabilities` to see what tier this install is on.

## Optional: Spotify (tiers 1 & 2)

vibing-supply does **not** ship a Spotify app — you bring your own. Free, takes a minute:

1. Register an app at <https://developer.spotify.com/dashboard>
   - Redirect URI: `http://127.0.0.1:8888/callback` (must be loopback IP, not `localhost`)
   - APIs used: check **Web API**
2. Copy the Client ID, then:

```bash
npx vibing-supply spotify-setup <client_id>   # one-time OAuth
npx vibing-supply sync all                    # seed Taste/Backfill/Liked cache
npx vibing-supply capabilities                # confirm what unlocked
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
