#!/usr/bin/env bash
# Claude Code status line script
# Reads JSON from stdin and outputs a formatted status line

python3 -c "
import sys, json, os

data = json.load(sys.stdin)

model = data.get('model', {}).get('display_name', 'Unknown')
used_pct = data.get('context_window', {}).get('used_percentage')
in_tok = data.get('context_window', {}).get('total_input_tokens', 0)
out_tok = data.get('context_window', {}).get('total_output_tokens', 0)

# Colors
R = '\033[0m'
B = '\033[1m'
D = '\033[2m'
CYAN = '\033[36m'
BLUE = '\033[34m'
MAGENTA = '\033[35m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RED = '\033[31m'

# Format tokens as K (thousands, no decimal)
def fmt_tok(n):
    return f'{n // 1000}K' if n >= 1000 else str(n)

# Shorten model name: 'Claude Opus 4.6' -> 'Opus 4.6'
import re
short_model = re.sub(r'\s*\(.*context\)', '', model.replace('Claude ', ''))
model_s = f'{D}{short_model}{R}'

# Context window size label
ctx_size = data.get('context_window', {}).get('context_window_size', 0)
ctx_label = f'{ctx_size // 1000000}M' if ctx_size >= 1000000 else f'{ctx_size // 1000}K' if ctx_size else ''

# Context
if used_pct is not None:
    pct = int(used_pct + 0.5)
    color = RED if pct >= 85 else YELLOW if pct >= 60 else GREEN
    ctx_s = f'{color}{pct}%{R} {D}i/o: {fmt_tok(in_tok)}/{fmt_tok(out_tok)}{R}'
else:
    ctx_s = f'{D}--{R}'

# Account: only show work / personal
cfg = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.realpath(os.path.expanduser('~/.claude'))
base = os.path.basename(cfg.rstrip('/'))
acct = base[len('.claude-'):] if base.startswith('.claude-') else ''
if acct == 'work':
    acct_s = f'{BLUE}work{R} '
elif acct == 'personal':
    acct_s = f'{MAGENTA}personal{R} '
else:
    acct_s = ''

size_s = f' ({ctx_label})' if ctx_label else ''
print(f' {acct_s}{model_s}{D}{size_s}{R} {ctx_s} ')
"
