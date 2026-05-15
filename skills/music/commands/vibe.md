---
description: Vibing-supply controls. `vibe claude` opens Claude FM.
allowed-tools: Bash(open:*)
---

# /vibe

Dispatch on `$ARGUMENTS`. If empty, list available subcommands. Otherwise
run exactly what the subcommand says — do not narrate, do not add
commentary. One line of confirmation is enough.

## Subcommands

### `claude`

Open Claude FM (a 24/7 live coding stream) in the default browser:

```bash
open "https://www.youtube.com/live/YmQ7jRgf4f0"
```

Then reply with exactly:

```
🎙️ Claude FM → https://www.youtube.com/live/YmQ7jRgf4f0
```

### (unknown / empty)

Print:

```
/vibe — available: claude
```
