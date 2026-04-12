---
name: vibing
description: Apply the "vibing" vibe — chill statusline with moon animation, relaxed spinner verbs, and calm tips.
---

# Vibing

Chill mode. Take it easy.

## What This Does

Applies the following to your current session:

**Statusline:** Progress bar + context info + countdown to midnight + rotating moon animation

**Spinner Verbs:** Vibing, Floating, Drifting, Cruising

**Tips:** "take it easy", "no rush", "let it flow"

## Apply

Read `vibe.json` from this skill's directory and apply the configuration:

1. Read `vibe.json` adjacent to this file
2. Set `spinnerVerbs` in settings: `{"mode": "replace", "verbs": ["Vibing", "Floating", "Drifting", "Cruising"]}`
3. Set `spinnerTips` in settings: `{"tips": ["take it easy", "no rush", "let it flow"], "excludeDefault": true}`
4. Generate statusline script from `statusline.segments` and configure in settings
5. Set `refreshInterval: 1` for animations

## Statusline Preview

```
████████████░░░░░░░░ 52% | Opus 4.6 | $1.20 | 84K  ⏳ 02:34:17 🌔
```
