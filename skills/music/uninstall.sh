#!/usr/bin/env bash
# uninstall.sh — reverse install.sh.
#
# Removes:
#   - UserPromptSubmit hook entries pointing at this skill's music-hook.sh
#   - ~/.claude/statuslines/music.sh
#   - the play-history pointer line in ~/.claude/CLAUDE.md
#
# Preserves:
#   - ~/.cache/music/play_history.md (your listening history)
#   - /tmp/music-current.json (ephemeral; gone on reboot anyway)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$REPO_DIR/bin"
COMMANDS_DIR="$REPO_DIR/commands"
SETTINGS="$HOME/.claude/settings.json"
STATUSLINES_DIR="$HOME/.claude/statuslines"
COMMANDS_USER_DIR="$HOME/.claude/commands"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
SUPPORT_DIR="$HOME/Library/Application Support/music"
PLIST="$HOME/Library/LaunchAgents/supply.music.poll.plist"
HOOK_MARK="$BIN_DIR/music-hook.sh"

say() { printf '\033[36m[music]\033[0m %s\n' "$*"; }

# 1. Strip our hook entries.
if [[ -f "$SETTINGS" ]]; then
  say "removing UserPromptSubmit hook entries"
  tmp="$(mktemp)"
  jq --arg m "$HOOK_MARK" '
    if .hooks.UserPromptSubmit then
      .hooks.UserPromptSubmit |= map(
        select(
          (.hooks // [])
          | all((.command // "") | (contains($m) | not))
        )
      )
    else . end
  ' "$SETTINGS" > "$tmp"
  mv -f "$tmp" "$SETTINGS"
fi

# 2. Remove statusline option.
if [[ -f "$STATUSLINES_DIR/music.sh" ]]; then
  say "removing $STATUSLINES_DIR/music.sh"
  rm -f "$STATUSLINES_DIR/music.sh"
fi

# 3. Remove CLAUDE.md pointer line(s) — match either the old play_history-only
#    pointer or the newer combined pointer that mentions now-playing.txt.
if [[ -f "$CLAUDE_MD" ]] && grep -qE "music/(now-playing\.txt|play_history\.md)" "$CLAUDE_MD"; then
  say "stripping music pointer from $CLAUDE_MD"
  tmp="$(mktemp)"
  grep -vE "music/(now-playing\.txt|play_history\.md)" "$CLAUDE_MD" > "$tmp" || true
  mv -f "$tmp" "$CLAUDE_MD"
fi

# 4. Strip slash command symlinks we own. Only remove links that
#    actually point back into this repo's commands/ dir — leaves user's
#    own files or third-party command files untouched.
if [[ -d "$COMMANDS_DIR" && -d "$COMMANDS_USER_DIR" ]]; then
  while IFS= read -r -d '' cmd_file; do
    base="$(basename "$cmd_file")"
    target="$COMMANDS_USER_DIR/$base"
    if [[ -L "$target" && "$(readlink "$target")" == "$cmd_file" ]]; then
      say "removing $target"
      rm -f "$target"
    fi
  done < <(find "$COMMANDS_DIR" -maxdepth 1 -type f -name '*.md' -print0)
fi

# 5. Stop and remove the launchd polling daemon.
if [[ -f "$PLIST" ]]; then
  say "unloading background poll daemon"
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
fi

# 6. Remove the launchd-friendly script copies (Application Support).
if [[ -d "$SUPPORT_DIR" ]]; then
  say "removing $SUPPORT_DIR"
  rm -f "$SUPPORT_DIR/poll.sh" "$SUPPORT_DIR/daemon.sh" \
        "$SUPPORT_DIR/music-enrich.sh" \
        "$SUPPORT_DIR/music-spotify-auth.sh" \
        "$SUPPORT_DIR/music-player-state.sh"
  rmdir "$SUPPORT_DIR" 2>/dev/null || true
fi

say "done. ~/.cache/music/play_history.md left intact."
