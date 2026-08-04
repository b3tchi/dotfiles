#!/bin/bash
[ -z "$TMUX" ] && exit 0
# Always clear first, then set only if question detected
tmux set-option -pu @waiting
input=$(cat)
# Stop payload has no last_assistant_message -- read the transcript instead
msg=$(echo "$input" | python3 -c "
import sys, json

payload = json.load(sys.stdin)
path = payload.get('transcript_path')
if not path:
    sys.exit(0)

last = ''
with open(path) as f:
    for line in f:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        m = rec.get('message') or {}
        if rec.get('type') != 'assistant' or m.get('role') != 'assistant':
            continue
        text = ''.join(
            c.get('text', '')
            for c in m.get('content', [])
            if isinstance(c, dict) and c.get('type') == 'text'
        )
        if text.strip():
            last = text
print(last)
" 2>/dev/null)
last_line=$(echo "$msg" | grep -v '^$' | grep -v '^```' | tail -1)
if [[ "$last_line" =~ \?[[:space:]]*$ ]]; then
  tmux set-option -p @waiting 1
fi
exit 0
