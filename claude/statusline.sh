#!/usr/bin/env bash
# Claude Code status line script
# Reads JSON from stdin and outputs a formatted status line (bash + jq)

json=$(cat)

# Pull fields in one jq pass (one per line; mapfile preserves empty fields)
mapfile -t f < <(
  jq -r '
    (.model.display_name // "Unknown"),
    (.context_window.used_percentage // ""),
    (.context_window.total_input_tokens // 0),
    (.context_window.total_output_tokens // 0),
    (.context_window.context_window_size // 0)
  ' <<<"$json"
)
model=${f[0]} used_pct=${f[1]} in_tok=${f[2]} out_tok=${f[3]} ctx_size=${f[4]}

# Colors
R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
CYAN=$'\033[36m'; BLUE=$'\033[34m'; MAGENTA=$'\033[35m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'

# Format tokens as K (thousands, no decimal)
fmt_tok() { local n=$1; (( n >= 1000 )) && echo "$((n / 1000))K" || echo "$n"; }

# Shorten model: 'Claude Opus 4.8 (1M context)' -> 'Opus 4.8'
short_model=${model#Claude }
short_model=$(sed -E 's/ *\([^)]*context\)//' <<<"$short_model")
model_s="${D}${short_model}${R}"

# Context window size label
if   (( ctx_size >= 1000000 )); then ctx_label="$((ctx_size / 1000000))M"
elif (( ctx_size >= 1000 ));    then ctx_label="$((ctx_size / 1000))K"
else ctx_label=""; fi

# Context %
if [[ -n $used_pct ]]; then
  pct=$(printf '%.0f' "$used_pct")
  if   (( pct >= 85 )); then color=$RED
  elif (( pct >= 60 )); then color=$YELLOW
  else color=$GREEN; fi
  ctx_s="${color}${pct}%${R} ${D}i/o: $(fmt_tok "$in_tok")/$(fmt_tok "$out_tok")${R}"
else
  ctx_s="${D}--${R}"
fi

# Account: only show work / personal
cfg=${CLAUDE_CONFIG_DIR:-$(realpath "$HOME/.claude")}
base=$(basename "${cfg%/}")
acct=""
[[ $base == .claude-* ]] && acct=${base#.claude-}
case $acct in
  work)     acct_s="${BLUE}work${R} " ;;
  personal) acct_s="${MAGENTA}personal${R} " ;;
  *)        acct_s="" ;;
esac

# Current datetime yymmdd-hhmm
clock_s=" ${D}last: $(date +%y%m%d-%H%M)${R}"

size_s=""; [[ -n $ctx_label ]] && size_s=" (${ctx_label})"
printf ' %s%s%s%s%s %s%s \n' "$acct_s" "$model_s" "$D" "$size_s" "$R" "$ctx_s" "$clock_s"
