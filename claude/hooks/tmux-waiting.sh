#!/bin/bash
[ -z "$TMUX" ] && exit 0
# Always clear first, then set only if question detected
tmux set-option -pu @waiting
input=$(cat)
msg=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_assistant_message',''))" 2>/dev/null)
last_line=$(echo "$msg" | grep -v '^$' | grep -v '^```' | tail -1)
if [[ "$last_line" =~ \?[[:space:]]*$ ]]; then
  tmux set-option -p @waiting 1
fi
exit 0
