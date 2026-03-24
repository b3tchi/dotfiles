#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
docker compose up -d 2>/dev/null
sleep 2

run() { docker compose exec -T -u testuser local bash -c "$1"; }

run 'ssh testuser@remote "tmux kill-server" 2>/dev/null; tmux -L thin kill-server 2>/dev/null; sleep 1'

echo "=== Connect 1 ==="
T1=$(run 'ssh testuser@remote "~/.local/bin/tmux-start start 0 local" 2>/dev/null | tr -d "[:space:]"')
echo "TARGET=$T1"
run "tmux -L thin -f /home/testuser/.dotfiles/tmux/tmux-thin-local.conf new-session -d -s thin -n conn1 \"ssh -t testuser@remote TMUX_TARGET=$T1 bash -li\""
sleep 3

echo "=== Connect 2 ==="
T2=$(run 'ssh testuser@remote "~/.local/bin/tmux-start start 0 local" 2>/dev/null | tr -d "[:space:]"')
echo "TARGET=$T2"
run "tmux -L thin new-window -d -n conn2 \"ssh -t testuser@remote TMUX_TARGET=$T2 bash -li\""
sleep 3

echo ""
echo "=== Results ==="
echo "Thin windows:"
run 'tmux -L thin list-windows -t thin -F "  #{window_name}:#{pane_dead}"'
echo "Remote sessions:"
run 'ssh testuser@remote "tmux list-sessions -F \"  #{session_name}:#{session_group}:#{session_attached}\""'

# run 'tmux -L thin kill-server; ssh testuser@remote "tmux kill-server" 2>/dev/null'
