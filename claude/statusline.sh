#!/usr/bin/env bash
# Claude Code status line script
# Reads JSON from stdin and outputs a formatted status line

python3 -c "
import sys, json, os, re

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

# Account: explicit via CLAUDE_CONFIG_DIR, else resolve ~/.claude symlink
cfg = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.realpath(os.path.expanduser('~/.claude'))
base = os.path.basename(cfg.rstrip('/'))
if base.startswith('.claude-'):
    acct = base[len('.claude-'):]
else:
    acct = base
acct_color = BLUE if acct == 'work' else MAGENTA if acct == 'personal' else CYAN
acct_s = f'{acct_color}{acct}{R}'

# Permission mode — parse latest from transcript jsonl (not in statusline JSON)
mode = ''
tx = data.get('transcript_path')
if tx and os.path.exists(tx):
    try:
        with open(tx, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            chunk = min(size, 131072)
            f.seek(-chunk, 2)
            tail = f.read().decode('utf-8', errors='ignore')
        matches = re.findall(r'\"permissionMode\":\"([^\"]+)\"', tail)
        if matches:
            mode = matches[-1]
    except Exception:
        pass
mode_map = {
    'plan': (CYAN, 'plan'),
    'acceptEdits': (YELLOW, 'edit'),
    'auto': (GREEN, 'auto'),
    'bypassPermissions': (RED, 'yolo'),
    'dontAsk': (YELLOW, 'noask'),
}
if mode in mode_map:
    mc, ml = mode_map[mode]
    mode_s = f' {mc}{ml}{R}'
else:
    mode_s = ''

size_s = f' ({ctx_label})' if ctx_label else ''
print(f' {acct_s}{mode_s} {model_s}{D}{size_s}{R} {ctx_s} ')
"
