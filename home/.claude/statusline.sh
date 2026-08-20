#!/usr/bin/env bash
# Claude Code Status Line
# Save to ~/.claude/statusline.sh and chmod +x
#
# Add to ~/.claude/settings.json:
# {
#   "statusLine": {
#     "type": "command",
#     "command": "~/.claude/statusline.sh",
#     "refreshInterval": 60
#   }
# }
set -euo pipefail

# Read JSON session data from stdin
INPUT=$(cat)

# --- Colors (ANSI-C quoting for real escape bytes) ---
reset=$'\e[0m'
bold=$'\e[1m'
dim=$'\e[2m'
red=$'\e[31m'
green=$'\e[32m'
yellow=$'\e[33m'
cyan=$'\e[36m'

j() { printf '%s' "$INPUT" | jq -r "$1"; }

# --- Model ---
model=$(j '.model.display_name // "unknown"')

# --- Context usage ---
input_tokens=$(j '.context_window.total_input_tokens // 0')
output_tokens=$(j '.context_window.total_output_tokens // 0')
ctx_size=$(j '.context_window.context_window_size // 200000')
used_tokens=$((input_tokens + output_tokens))
if [ "$ctx_size" -gt 0 ]; then
  ctx_pct=$((used_tokens * 100 / ctx_size))
else
  ctx_pct=0
fi

# Color a 0-100 percentage: green < 60, yellow 60-84, red >= 85
pct_color() {
  if   [ "$1" -lt 60 ]; then printf '%s' "$green"
  elif [ "$1" -lt 85 ]; then printf '%s' "$yellow"
  else                       printf '%s' "$red"
  fi
}

# Color context percentage: green < 40, yellow 40-70, red > 70
if [ "$ctx_pct" -lt 40 ]; then
  ctx_color=$green
elif [ "$ctx_pct" -lt 70 ]; then
  ctx_color=$yellow
else
  ctx_color=$red
fi

# --- Rate limits (Claude.ai Pro/Max only; absent on API billing
#     and until the first API response of the session) ---

# Unix epoch -> compact "3d4h" / "1h39m" / "12m"
fmt_eta() {
  local delta=$(( $1 - $(date +%s) ))
  if   [ "$delta" -le 0 ];     then printf 'now'
  elif [ "$delta" -ge 86400 ]; then printf '%dd%dh' $((delta/86400)) $(((delta%86400)/3600))
  elif [ "$delta" -ge 3600 ];  then printf '%dh%dm' $((delta/3600))  $(((delta%3600)/60))
  else                              printf '%dm' $((delta/60))
  fi
}

# limit_seg <label> <five_hour|seven_day>  -> "" when the field is absent
limit_seg() {
  local label=$1 key=$2 raw pct at out
  raw=$(j ".rate_limits.${key}.used_percentage // empty")
  [ -n "$raw" ] || return 0
  pct=$(printf '%.0f' "$raw")                      # 23.5 -> 24 (bash math needs an int)
  out="${dim}${label}${reset} $(pct_color "$pct")${pct}%${reset}"
  at=$(j ".rate_limits.${key}.resets_at // empty")
  [ -n "$at" ] && out+=" ${dim}($(fmt_eta "$at"))${reset}"
  printf '%s' "$out"
}

limits=""
for seg in "$(limit_seg 5h five_hour)" "$(limit_seg 7d seven_day)"; do
  [ -n "$seg" ] && limits+=" ${dim}|${reset} ${seg}"
done

# --- Cost ---
total_cost=$(j '.cost.total_cost_usd // 0')
cost_str=$(printf '$%.2f' "$total_cost")

# --- Current directory (shortened to last 2 path components) ---
cwd=$(j '.cwd // empty')
if [ -n "$cwd" ]; then
  dir_str="${cwd/#$HOME/\~}"
  dir_str=$(echo "$dir_str" | awk -F/ '{if(NF>2) print $(NF-1)"/"$NF; else print $0}')
else
  dir_str="?"
fi

# --- Git info ---
branch=""
git_status=""
if [ -n "$cwd" ] && command -v git &>/dev/null; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -n "$branch" ]; then
    staged=$(git -C "$cwd" --no-optional-locks diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    unstaged=$(git -C "$cwd" --no-optional-locks diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    untracked=$(git -C "$cwd" --no-optional-locks ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    git_status=" ${cyan}${branch}${reset}"
    [ "$staged" -gt 0 ] && git_status+=" ${green}+${staged}${reset}"
    [ "$unstaged" -gt 0 ] && git_status+=" ${yellow}~${unstaged}${reset}"
    [ "$untracked" -gt 0 ] && git_status+=" ${red}?${untracked}${reset}"
  fi
fi

# --- Format human-readable token count ---
if [ "$used_tokens" -ge 1000 ]; then
  tokens_str="$((used_tokens / 1000))k/$((ctx_size / 1000))k"
else
  tokens_str="${used_tokens}/${ctx_size}"
fi

# --- Output ---
# Line 1: model, directory, git
printf "%s%s%s%s |%s %s%s%s%s\n" \
  "$bold" "$model" "$reset" \
  "$dim" "$reset" "$bold" "$dir_str" "$reset" "$git_status"

# Line 2: context, cost, rate limits
printf "%s%d%%%s %s%s |%s %s%s\n" \
  "$ctx_color" "$ctx_pct" "$reset" "$tokens_str" \
  "$dim" "$reset" \
  "$cost_str" "$limits"
