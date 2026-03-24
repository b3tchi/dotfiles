#!/usr/bin/env bash
# Integration tests for tmux-to-workstation and tmux-from-workstation
# Orchestrates via docker exec against running containers
set -euo pipefail

cd "$(dirname "$0")"

PASS=0
FAIL=0

check() {
    if [ "$2" = "PASS" ]; then
        echo "  PASS: $1"
        ((PASS++))
    else
        echo "  FAIL: $1 ($3)"
        ((FAIL++))
    fi
}

run_local() { docker compose exec -T -u testuser local "$@"; }

cleanup_all() {
    run_local bash -c '
        tmux kill-server 2>/dev/null
        tmux -L thin kill-server 2>/dev/null
        tmux -L remote kill-server 2>/dev/null
        ssh testuser@remote "tmux kill-server 2>/dev/null; tmux -L thin kill-server 2>/dev/null" 2>/dev/null
        true
    '
}

# --- Setup ---
echo "=== Building and starting containers ==="
docker compose build --quiet
docker compose up -d

echo "Waiting for SSH..."
for i in $(seq 1 30); do
    if run_local bash -c 'ssh -o ConnectTimeout=1 testuser@remote cat /etc/hostname 2>/dev/null' | grep -q remote; then
        break
    fi
    sleep 1
done

# ============================================================
echo ""
echo "=== to-workstation tests ==="
# ============================================================

cleanup_all
sleep 1

# 1. tmux-start creates session on remote
echo ""
echo "--- Test 1: tmux-start on remote ---"
TARGET=$(run_local bash -c 'ssh testuser@remote "~/.local/bin/tmux-start start 0 local" 2>/dev/null')
echo "$TARGET" | grep -q "local_0" && check "tmux-start returns target" "PASS" || check "tmux-start returns target" "FAIL" "got: $TARGET"

# 2. Create thin session with SSH to remote
echo ""
echo "--- Test 2: thin session creation ---"
PANE_ID=$(run_local bash -c '
    SSH_CMD="ssh -t testuser@remote \"export TMUX_TARGET=\$(~/.local/bin/tmux-start start 0 local); bash -li\""
    tmux -L thin -f /home/testuser/.dotfiles/tmux/tmux-thin-local.conf new-session -d -P -F "#{pane_id}" -s thin -n "remote_local" "$SSH_CMD" 2>&1
')
sleep 3

ALIVE=$(run_local bash -c 'tmux -L thin list-windows -t thin -F "#{pane_dead}" 2>/dev/null')
[ "$ALIVE" = "0" ] && check "SSH pane alive" "PASS" || check "SSH pane alive" "FAIL" "pane_dead=$ALIVE"

# 3. Pane metadata
echo ""
echo "--- Test 3: pane metadata ---"
run_local bash -c "
    tmux -L thin set-option -p -t $PANE_ID @remote_name remote
    tmux -L thin set-option -p -t $PANE_ID @remote_host testuser@remote
    tmux -L thin set-option -p -t $PANE_ID @remote_session local
"

RNAME=$(run_local bash -c "tmux -L thin display-message -t $PANE_ID -p '#{@remote_name}' 2>/dev/null")
[ "$RNAME" = "remote" ] && check "@remote_name" "PASS" || check "@remote_name" "FAIL" "got: $RNAME"

TITLE=$(run_local bash -c "tmux -L thin display-message -t $PANE_ID -p '#{?@remote_name,[#{@remote_name}],thin}' 2>/dev/null")
[ "$TITLE" = "[remote]" ] && check "title string" "PASS" || check "title string" "FAIL" "got: $TITLE"

# 4. Remote session exists
echo ""
echo "--- Test 4: remote session ---"
RSESS=$(run_local bash -c 'ssh testuser@remote "tmux list-sessions -F \"#{session_name}:#{session_group}\"" 2>/dev/null')
echo "$RSESS" | grep -q "local" && check "remote has local group" "PASS" || check "remote has local group" "FAIL" "got: $RSESS"

# 5. remain-on-exit
echo ""
echo "--- Test 5: remain-on-exit ---"
SSH_PID=$(run_local bash -c 'tmux -L thin list-panes -t thin -F "#{pane_pid}" 2>/dev/null')
run_local bash -c "kill $SSH_PID 2>/dev/null"
sleep 2

DEAD=$(run_local bash -c 'tmux -L thin list-windows -t thin -F "#{pane_dead}" 2>/dev/null')
[ "$DEAD" = "1" ] && check "pane dead after kill" "PASS" || check "pane dead after kill" "FAIL" "pane_dead=$DEAD"

# 6. list shows dead
echo ""
echo "--- Test 6: list command ---"
LIST=$(run_local bash -c 'nu -c "\$env.HOME = \"/home/testuser\"; nu /home/testuser/.local/bin/tmux-to-workstation list" 2>&1')
echo "$LIST" | grep -q "(dead)" && check "list shows (dead)" "PASS" || check "list shows (dead)" "FAIL" "got: $LIST"

# 7. Kill dead window
echo ""
echo "--- Test 7: kill dead window ---"
DEAD_ID=$(run_local bash -c 'tmux -L thin list-windows -t thin -F "#{window_id}:#{pane_dead}" 2>/dev/null | grep ":1$" | cut -d: -f1')
if [ -n "$DEAD_ID" ]; then
    run_local bash -c "tmux -L thin kill-window -t $DEAD_ID"
    check "killed dead window" "PASS"
else
    check "killed dead window" "FAIL" "no dead window found"
fi

REMAINING=$(run_local bash -c 'tmux -L thin list-windows -t thin 2>/dev/null | wc -l')
[ "$REMAINING" = "0" ] && check "no windows remain" "PASS" || check "no windows remain" "FAIL" "remaining: $REMAINING"

# 8. Socket isolation
echo ""
echo "--- Test 8: socket isolation ---"
run_local bash -c '
    tmux new-session -d -s default_sess
    tmux -L thin new-session -d -s thin_sess -f /home/testuser/.dotfiles/tmux/tmux-thin-local.conf
    tmux -L remote new-session -d -s remote_sess
'

DC=$(run_local bash -c 'tmux list-sessions 2>/dev/null | wc -l')
TC=$(run_local bash -c 'tmux -L thin list-sessions 2>/dev/null | wc -l')
RC=$(run_local bash -c 'tmux -L remote list-sessions 2>/dev/null | wc -l')

[ "$DC" = "1" ] && check "default socket isolated" "PASS" || check "default socket isolated" "FAIL" "count: $DC"
[ "$TC" = "1" ] && check "thin socket isolated" "PASS" || check "thin socket isolated" "FAIL" "count: $TC"
[ "$RC" = "1" ] && check "remote socket isolated" "PASS" || check "remote socket isolated" "FAIL" "count: $RC"

# 9. Help output
echo ""
echo "--- Test 9: script help ---"
HELP_TO=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-to-workstation 2>&1')
echo "$HELP_TO" | grep -q "local thin, remote fat" && check "to-workstation help" "PASS" || check "to-workstation help" "FAIL"

HELP_FROM=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-from-workstation 2>&1')
echo "$HELP_FROM" | grep -q "local fat, remote thin" && check "from-workstation help" "PASS" || check "from-workstation help" "FAIL"

HELP_SSH=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-ssh 2>&1')
echo "$HELP_SSH" | grep -q "txs" && check "tmux-ssh help (regression)" "PASS" || check "tmux-ssh help (regression)" "FAIL"

# ============================================================
echo ""
echo "=== from-workstation tests ==="
# ============================================================

cleanup_all
sleep 1

# 10. Requires fat tmux
echo ""
echo "--- Test 10: requires fat tmux ---"
ERR=$(run_local bash -c 'nu -c "\$env.HOME = \"/home/testuser\"; nu /home/testuser/.local/bin/tmux-from-workstation connect testuser@remote" 2>&1')
echo "$ERR" | grep -q "must be inside" && check "rejects when not in tmux" "PASS" || check "rejects when not in tmux" "FAIL" "got: $ERR"

# 11. Connect creates remote thin
echo ""
echo "--- Test 11: connect creates remote thin ---"
run_local bash -c '
    tmux new-session -d -s fat_test
    tmux send-keys -t fat_test "nu /home/testuser/.local/bin/tmux-from-workstation connect testuser@remote" Enter
'
sleep 4

RSESS=$(run_local bash -c 'ssh testuser@remote "tmux -L thin list-sessions -F \"#{session_name}\"" 2>/dev/null')
[ -n "$RSESS" ] && check "remote thin session created" "PASS" || check "remote thin session created" "FAIL" "no sessions"

HOST_OPT=$(run_local bash -c 'tmux display-message -t fat_test -p "#{@thin_remote_host}" 2>/dev/null')
echo "$HOST_OPT" | grep -q "remote" && check "pane has @thin_remote_host" "PASS" || check "pane has @thin_remote_host" "FAIL" "got: $HOST_OPT"

# 12. List remote thin sessions
echo ""
echo "--- Test 12: list ---"
LIST=$(run_local bash -c 'nu -c "\$env.HOME = \"/home/testuser\"; nu /home/testuser/.local/bin/tmux-from-workstation list -- testuser@remote" 2>&1')
echo "$LIST" | grep -q "remote\|detached\|attached" && check "list shows sessions" "PASS" || check "list shows sessions" "FAIL" "got: $LIST"

# 13. Cleanup kills unattached
echo ""
echo "--- Test 13: cleanup ---"
run_local bash -c 'ssh testuser@remote "tmux -L thin new-session -d -s cleanup_test" 2>/dev/null'

CLEANUP=$(run_local bash -c 'nu -c "\$env.HOME = \"/home/testuser\"; nu /home/testuser/.local/bin/tmux-from-workstation cleanup -- testuser@remote" 2>&1')
echo "$CLEANUP" | grep -q "Killed\|cleanup_test" && check "cleanup kills sessions" "PASS" || check "cleanup kills sessions" "FAIL" "got: $CLEANUP"

ALIVE=$(run_local bash -c 'ssh testuser@remote "tmux -L thin has-session -t cleanup_test 2>/dev/null; echo \$?" 2>/dev/null')
[ "$ALIVE" = "1" ] && check "cleanup_test killed" "PASS" || check "cleanup_test killed" "FAIL" "exit: $ALIVE"

# --- Summary ---
cleanup_all
docker compose down --quiet 2>/dev/null

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="

exit $FAIL
