---
name: create-vibe
description: Create a new vibe pack for vibing.supply. Use this when the user wants to create, design, or build a new vibe theme — including when they say things like "make a vibe", "new vibe", "I want a vibe that...", "create a theme for my statusline", or describe a mood/aesthetic they want their coding agent to have.
---

# Create Vibe

Guide the user through creating a new vibe for [vibing.supply](https://vibing.supply). A vibe is a theme pack that customizes a coding agent's statusline, spinner verbs, and tips.

## Process

Walk through each section with the user conversationally. Don't dump all questions at once — ask one section at a time, offer suggestions, and build the vibe together.

### 1. Identity

Ask for:
- **name** — lowercase, alphanumeric + hyphens only (e.g., `midnight-coder`, `zen`, `yolo`). This becomes the directory name and install command.
- **displayName** — human-readable name shown on the card (e.g., "Midnight Coder")
- **description** — one sentence that captures the vibe's mood (e.g., "Late night energy. Ship it before sunrise.")
- **author** — GitHub username or name

### 2. Statusline Segments

The statusline is built from segments rendered left to right. Walk through each segment type and ask if they want it:

**progress-bar** — context window usage bar
```json
{
  "type": "progress-bar",
  "width": 20,
  "colors": {
    "low": "#22c55e",
    "mid": "#eab308",
    "high": "#ef4444",
    "thresholds": [60, 80]
  }
}
```
Ask: width (characters), colors for low/mid/high usage, threshold percentages.

**text** — templated info display
```json
{
  "type": "text",
  "template": "{ctx_pct}% | {model} | {cost} | {tokens}"
}
```
Available variables: `{ctx_pct}`, `{model}`, `{cost}`, `{tokens}`.
Ask: which variables to show and what separator/format.

**countdown** — timer
```json
{
  "type": "countdown",
  "style": "to-midnight"
}
```
Styles: `to-midnight`, `duration`, `to-time`.
Ask: what kind of countdown fits their vibe.

**animation** — cycling emoji/characters
```json
{
  "type": "animation",
  "frames": ["🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘"],
  "interval": 0.5,
  "trigger": "time"
}
```
Ask: what emoji or characters to cycle through, how fast (interval in seconds), trigger type (`time` or `hook`).

Suggest creative ideas based on the vibe's mood. A "yolo" vibe might use fire emoji, a "zen" vibe might use breathing dots, a "retro" vibe might use braille spinners.

### 3. Spinner Verbs

These replace the "Thinking..." text while the agent works.

```json
{
  "mode": "replace",
  "verbs": ["Vibing", "Floating", "Drifting", "Cruising"]
}
```

Ask: 3-5 verbs that match the vibe's personality. Suggest options based on the mood.
Mode is usually `replace`. Use `append` only if they want to keep the defaults and add more.

### 4. Spinner Tips

Messages shown while the agent works.

```json
{
  "tips": ["take it easy", "no rush", "let it flow"],
  "excludeDefault": true
}
```

Ask: 3-5 short tips/messages. These should feel like the vibe is talking to you.
Ask if they want to keep default tips (`excludeDefault: false`) or replace entirely.

## Generate Files

Once all sections are collected, generate two files:

### vibe.json

Write to `skills/vibe/vibes/<name>/vibe.json`:

```json
{
  "name": "<name>",
  "displayName": "<displayName>",
  "description": "<description>",
  "author": "<author>",
  "statusline": {
    "segments": [<collected segments>]
  },
  "spinnerVerbs": {
    "mode": "<mode>",
    "verbs": [<collected verbs>]
  },
  "spinnerTips": {
    "tips": [<collected tips>],
    "excludeDefault": <true|false>
  },
  "install": "npx vibing-supply use <name>"
}
```

### SKILL.md

Write to `skills/vibe/vibes/<name>/SKILL.md`:

```markdown
---
name: <name>
description: Apply the "<displayName>" vibe — <one line summary of what it does>.
---

# <displayName>

<description>

## What This Does

Applies the following to your current session:

**Statusline:** <describe segments in plain language>

**Spinner Verbs:** <comma-separated list>

**Tips:** <quoted, comma-separated list>

## Apply

Read `vibe.json` from this skill's directory and apply the configuration:

1. Read `vibe.json` adjacent to this file
2. Set `spinnerVerbs` in settings
3. Set `spinnerTips` in settings
4. Generate statusline script from `statusline.segments` and configure in settings
5. Set `refreshInterval: 1` for animations

## Statusline Preview

\`\`\`
<render a text preview of what the statusline looks like>
\`\`\`
```

## After Generation

1. Validate vibe.json against the schema at `schema/vibe.schema.json`
2. Show the user a preview of what their statusline will look like
3. Commit both files
4. Tell them: "Your vibe is ready! To submit it to vibing.supply, push and open a PR to `Yukioa2z/vibes`."
