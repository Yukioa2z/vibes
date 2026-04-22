#!/usr/bin/env bash
# uninstall.sh — reverse install.sh.
#
# Removes:
#   - UserPromptSubmit hook entries pointing at this skill's vibe-hook.sh
#   - ~/.claude/statuslines/attune.sh
#   - the play-history pointer line in ~/.claude/CLAUDE.md
#
# Preserves:
#   - ~/.cache/vibe/play_history.md (your listening history)
#   - /tmp/vibe-current.json (ephemeral; gone on reboot anyway)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$REPO_DIR/bin"
SETTINGS="$HOME/.claude/settings.json"
STATUSLINES_DIR="$HOME/.claude/statuslines"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
SUPPORT_DIR="$HOME/Library/Application Support/vibe"
PLIST="$HOME/Library/LaunchAgents/supply.vibe.poll.plist"
HOOK_MARK="$BIN_DIR/vibe-hook.sh"

say() { printf '\033[36m[attune]\033[0m %s\n' "$*"; }

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
if [[ -f "$STATUSLINES_DIR/attune.sh" ]]; then
  say "removing $STATUSLINES_DIR/attune.sh"
  rm -f "$STATUSLINES_DIR/attune.sh"
fi

# 3. Remove CLAUDE.md pointer line.
if [[ -f "$CLAUDE_MD" ]] && grep -qF "vibe/play_history.md" "$CLAUDE_MD"; then
  say "stripping play-history pointer from $CLAUDE_MD"
  tmp="$(mktemp)"
  grep -vF "vibe/play_history.md" "$CLAUDE_MD" > "$tmp" || true
  mv -f "$tmp" "$CLAUDE_MD"
fi

# 4. Stop and remove the launchd polling daemon.
if [[ -f "$PLIST" ]]; then
  say "unloading background poll daemon"
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
fi

# 5. Remove the launchd-friendly script copies (Application Support).
if [[ -d "$SUPPORT_DIR" ]]; then
  say "removing $SUPPORT_DIR"
  rm -f "$SUPPORT_DIR/poll.sh" "$SUPPORT_DIR/daemon.sh"
  rmdir "$SUPPORT_DIR" 2>/dev/null || true
fi

say "done. ~/.cache/vibe/play_history.md left intact."
