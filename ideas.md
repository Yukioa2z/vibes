# Vibe Ideas

## Data Visualization
- **Sparkline** — `▁▂▃▄▅▆▇█` token burn trend, append a point each refresh
- **Burn rate** — $/min realtime burn rate, flash red above threshold
- **Context gradient** — ANSI 256 color smooth gradient bar, not discrete 3-color

## Mood / Atmosphere
- **Tamagotchi** — ASCII creature reacts to context usage: `(◕‿◕)` happy → `(⊙_⊙)` nervous → `(×_×)` dead
- **Weather sync** — curl wttr.in, map real weather to statusline vibe
- **Seasonal** — auto-switch theme by date: 🌸 spring, 🌊 summer, 🍂 autumn, ❄️ winter

## Productivity
- **Pomodoro** — built-in 25/5 timer with progress bar per phase
- **Git pulse** — `3 commits · last 12m ago` today's commit count + recency
- **Lines changed** — `+142 -37` realtime diff stats for current session

## Visual Effects
- **Braille animation** — 2x4 pixel micro-animations (bouncing ball, snake)
- **Rainbow cycle** — ANSI 256 color rainbow shift across text, offset each refresh
- **Matrix rain** — single-line random green characters cycling
- **1D cellular automata** — Conway-style using `█` and ` ` in one line

## OSC 8 Links
- **Cost → dashboard** — click cost to open Anthropic usage page
- **PR link** — detect open PR on current branch, show clickable link
- **Error jump** — click to open error details on failure

## Combo Ideas
- **Tamagotchi + Sparkline** — creature with a sparkline graph behind it showing token burn history
- **Pomodoro + Mood** — creature gets tired near end of work phase, happy during break
- **Weather + Seasonal** — real weather data with seasonal theme overlay

---

## Session Hooks

Observable behaviors in a Claude Code session that vibes can react to.

### Context Lifecycle
- `ctx_pct` change — gradual increase in context usage
- `compact` — context compression triggered, ctx_pct drops sharply
- `session_start` / `session_end`
- `ctx_danger` — context approaching limit (90%+)

### Thinking & Reasoning
- `thinking_start` / `thinking_end` — extended thinking
- `thinking_duration` — short vs long thinking
- `thinking_stuck` — long thinking with no output

### Tool Use
- `file_read` / `file_edit` / `file_write`
- `grep` / `glob` — search operations
- `bash_run` — shell command execution
- `bash_slow` — command taking a long time
- `bash_fail` — exit code != 0
- `lsp_call`

### Code Operations
- `commit`
- `push`
- `pull` / `fetch`
- `branch_create` / `branch_switch`
- `merge` / `rebase`
- `pr_create` / `pr_review`
- `diff_size` — lines added/removed

### Agent Behavior
- `subagent_spawn` — child agent created
- `subagent_done` / `subagent_fail`
- `parallel_agent_count` — number of concurrent agents
- `worktree_create`

### Memory & Planning
- `memorize` — writing to memory
- `recall` — reading from memory
- `plan_create` / `plan_update`
- `todo_create` / `todo_complete` / `todo_update`
- `task_progress` — task completion changes

### User Interaction
- `user_message` — user sends input
- `user_wait` — agent response latency
- `permission_denied` — user rejects a tool call
- `user_interrupt` — Ctrl+C or interrupt
- `user_idle` — long silence from user

### MCP & External
- `mcp_call` — MCP tool invocation (Figma, Playwright, etc.)
- `web_fetch` / `web_search`
- `screenshot` — image read
- `browser_action`

### Cost
- `burn_rate` — $/min spend rate
- `token_rate` — tokens/s consumption
- `single_response_cost`
- `cost_milestone` — cumulative cost hits $1, $5, $10...

### Build & Test
- `dev_server_start`
- `build_success` / `build_fail`
- `test_pass` / `test_fail`
- `lint_error`

### Meta / Streaks
- `success_streak` — N consecutive tool calls without error
- `debug_loop` — N consecutive bash failures (stuck in debug)
- `idle` — agent waiting, no activity
- `model_switch` — Opus → Sonnet → Haiku
- `fast_mode_toggle`

---

## Hook → Vibe Reaction Examples

| Hook | Reaction |
|---|---|
| `compact` | tamagotchi barfs `(>_<)💦`, sparkline cliff drop |
| `subagent_spawn` | creature splits `(◕‿◕) → (◕‿◕)(◕‿◕)` |
| `commit` | creature celebrates `\(◕‿◕)/🎉` |
| `bash_fail` | creature explodes `(×_×)💥` |
| `cost_milestone $10` | statusline catches fire `🔥🔥🔥` |
| `user_idle` | creature falls asleep `(-_-)zzz` |
| `permission_denied` | creature gets slapped `(T_T)` |
| `success_streak 5+` | creature glows `✨(◕‿◕)✨` |
| `debug_loop 3+` | creature confused `(⊙_⊙)?` |
| `thinking_stuck` | creature meditating `(  ᵕ ᵕ )🧘` |
| `pr_create` | creature ships it `(◕‿◕)🚀` |
| `test_pass` | creature flexes `(◕‿◕)💪` |
| `test_fail` | creature ducks `(°△°)🙈` |
