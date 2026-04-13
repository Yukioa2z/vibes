#!/bin/bash
input=$(cat)

CTX_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
COST_FMT=$(printf '$%.2f' "$COST")

RST='\033[0m'
DIM='\033[2m'

# --- Tamagotchi face based on context usage ---
if [ "$CTX_PCT" -ge 90 ] 2>/dev/null; then
  FACE='(×_×)'
  FACE_CLR='\033[31m'  # red
elif [ "$CTX_PCT" -ge 70 ] 2>/dev/null; then
  FACE='(°△°)'
  FACE_CLR='\033[31m'  # red
elif [ "$CTX_PCT" -ge 50 ] 2>/dev/null; then
  FACE='(⊙_⊙)'
  FACE_CLR='\033[33m'  # yellow
elif [ "$CTX_PCT" -ge 30 ] 2>/dev/null; then
  FACE='(•‿•)'
  FACE_CLR='\033[33m'  # yellow
else
  FACE='(◕‿◕)'
  FACE_CLR='\033[32m'  # green
fi

# --- Sparkline history ---
HIST_FILE="/tmp/.claude-sparkline-$$"
# Use a shared file keyed by parent PID to persist across refreshes
HIST_FILE="/tmp/.claude-sparkline-${PPID}"

# Append current value
echo "$CTX_PCT" >> "$HIST_FILE"

# Keep last 16 values
tail -16 "$HIST_FILE" > "${HIST_FILE}.tmp" && mv "${HIST_FILE}.tmp" "$HIST_FILE"

SPARK_CHARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
SPARKLINE=""

while IFS= read -r val; do
  # Map 0-100 to index 0-7
  idx=$((val * 7 / 100))
  [ "$idx" -gt 7 ] && idx=7
  [ "$idx" -lt 0 ] && idx=0

  # Color per bar
  if [ "$val" -ge 80 ] 2>/dev/null; then
    c='\033[31m'
  elif [ "$val" -ge 60 ] 2>/dev/null; then
    c='\033[33m'
  else
    c='\033[32m'
  fi
  SPARKLINE+="${c}${SPARK_CHARS[$idx]}${RST}"
done < "$HIST_FILE"

# Pad sparkline to 16 chars if not enough history
HIST_LEN=$(wc -l < "$HIST_FILE" | tr -d ' ')
PAD=$((16 - HIST_LEN))
PADDING=""
if [ "$PAD" -gt 0 ]; then
  PADDING=$(printf "${DIM}%0.s▁${RST}" $(seq 1 $PAD))
fi

# --- Heartbeat ---
BEAT_IDX=$(python3 -c "import time; print(int(time.time()) % 2)")
if [ "$BEAT_IDX" -eq 0 ]; then
  HEART='\033[31m♥\033[0m'
else
  HEART='\033[2m♡\033[0m'
fi

# --- Output ---
printf "${FACE_CLR}${FACE}${RST} ${PADDING}${SPARKLINE} ${DIM}${CTX_PCT}%%${RST} | ${MODEL} | ${COST_FMT} ${HEART}\n"
