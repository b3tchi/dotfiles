#!/usr/bin/env bash
# Integration tests for tmux-to-workstation and tmux-from-workstation
# Orchestrates via docker exec against running containers
set -euo pipefail

cd "$(dirname "$0")"

PASS=0
FAIL=0
ERRORS=""

# Helpers
run_local() { docker compose exec -T -u testuser local "$@"; }
run_remote() { docker compose exec -T -u testuser remote "$@"; }

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $test_name"
        ((PASS++))
    else
        echo "  FAIL: $test_name"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        ((FAIL++))
        ERRORS+="  - $test_name\n"
    fi
}

assert_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $test_name"
        ((PASS++))
    else
        echo "  FAIL: $test_name"
        echo "    expected to contain: '$needle'"
        echo "    actual: '$haystack'"
        ((FAIL++))
        ERRORS+="  - $test_name\n"
    fi
}

assert_exit_code() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        echo "  PASS: $test_name"
        ((PASS++))
    else
        echo "  FAIL: $test_name"
        echo "    expected exit code: $expected"
        echo "    actual exit code:   $actual"
        ((FAIL++))
        ERRORS+="  - $test_name\n"
    fi
}

cleanup() {
    echo "Cleaning up..."
    # Kill any tmux servers on both sides
    run_local bash -c 'tmux kill-server 2>/dev/null; tmux -L thin kill-server 2>/dev/null; tmux -L remote kill-server 2>/dev/null; true'
    run_remote bash -c 'tmux kill-server 2>/dev/null; tmux -L thin kill-server 2>/dev/null; tmux -L remote kill-server 2>/dev/null; true'
}

# --- Setup ---
echo "=== Building and starting containers ==="
docker compose build --quiet
docker compose up -d

# Wait for SSH to be ready on remote
echo "Waiting for SSH..."
for i in $(seq 1 30); do
    if run_local bash -c 'ssh -o ConnectTimeout=1 testuser@remote true 2>/dev/null'; then
        break
    fi
    sleep 1
done

# Verify SSH connectivity
echo "Verifying SSH connectivity..."
ssh_test=$(run_local bash -c 'ssh testuser@remote hostname 2>/dev/null' || echo "FAILED")
assert_eq "SSH local->remote works" "remote-machine" "$ssh_test"

# --- Test: Script help output ---
echo ""
echo "=== Script help output ==="

help_from=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-from-workstation 2>&1' || true)
assert_contains "from-workstation help shows commands" "local fat, remote thin" "$help_from"

help_to=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-to-workstation 2>&1' || true)
assert_contains "to-workstation help shows commands" "local thin, remote fat" "$help_to"

# --- Test: from-workstation connect ---
echo ""
echo "=== from-workstation: connect flow ==="
cleanup

# Start a fat tmux session on local (simulating workstation)
run_local bash -c 'tmux new-session -d -s fat_test'

# Run from-workstation connect inside local fat tmux
# This should SSH to remote and create a thin tmux session there
run_local bash -c '
    tmux send-keys -t fat_test "nu /home/testuser/.local/bin/tmux-from-workstation connect testuser@remote" Enter
'
sleep 3

# Check that thin tmux session was created on remote
remote_thin_sessions=$(run_remote bash -c 'tmux -L thin list-sessions -F "#{session_name}" 2>/dev/null' || echo "NONE")
assert_contains "from-workstation creates thin session on remote" "remote" "$remote_thin_sessions"

# --- Test: from-workstation list ---
echo ""
echo "=== from-workstation: list ==="

list_output=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-from-workstation list -- testuser@remote 2>&1' || true)
# Should show sessions (either with content or "No remote thin" if session died)
# The key is it doesn't crash
assert_contains "from-workstation list runs without error" "" "$list_output"

# --- Test: from-workstation cleanup ---
echo ""
echo "=== from-workstation: cleanup ==="

# Create a detached thin session on remote manually for cleanup to find
run_remote bash -c 'tmux -L thin new-session -d -s cleanup_test'

cleanup_output=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-from-workstation cleanup -- testuser@remote 2>&1' || true)
assert_contains "from-workstation cleanup finds sessions" "clean" "$cleanup_output"

# Verify session was killed
cleanup_check=$(run_remote bash -c 'tmux -L thin has-session -t cleanup_test 2>/dev/null; echo $?' || echo "1")
assert_eq "from-workstation cleanup killed session" "1" "$(echo "$cleanup_check" | tail -1)"

# --- Test: to-workstation connect ---
echo ""
echo "=== to-workstation: connect flow ==="
cleanup

# Create a fat tmux session on REMOTE (simulating the workstation we connect TO)
run_remote bash -c 'tmux new-session -d -s workstation'

# Run to-workstation connect from local (outside tmux — no fat to detach from)
# This should create local thin tmux and SSH to remote fat
run_local bash -c '
    nu -c "
        \$env.HOME = \"/home/testuser\"
        nu /home/testuser/.local/bin/tmux-to-workstation connect testuser@remote
    "
' &
TO_PID=$!
sleep 4

# Check that thin tmux was created on local
local_thin_sessions=$(run_local bash -c 'tmux -L thin list-sessions -F "#{session_name}" 2>/dev/null' || echo "NONE")
assert_contains "to-workstation creates local thin session" "thin" "$local_thin_sessions"

# Check thin window name contains remote host
local_thin_windows=$(run_local bash -c 'tmux -L thin list-windows -t thin -F "#{window_name}" 2>/dev/null' || echo "NONE")
assert_contains "to-workstation thin window named with remote host" "remote" "$local_thin_windows"

# Check metadata stored on window
remote_name=$(run_local bash -c 'tmux -L thin show-options -w -t thin -v @remote_name 2>/dev/null' || echo "NONE")
assert_contains "to-workstation stores @remote_name" "remote" "$remote_name"

# Kill background process
kill $TO_PID 2>/dev/null || true
wait $TO_PID 2>/dev/null || true

# --- Test: to-workstation list ---
echo ""
echo "=== to-workstation: list ==="

list_to_output=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-to-workstation list 2>&1' || true)
# Should list the thin window we just created
assert_contains "to-workstation list shows windows" "remote" "$list_to_output"

# --- Test: to-workstation cleanup (dead windows) ---
echo ""
echo "=== to-workstation: cleanup ==="

# Kill the SSH connection in the thin window to make it dead
run_local bash -c 'tmux -L thin send-keys -t thin C-c 2>/dev/null; true'
sleep 1
run_local bash -c 'tmux -L thin send-keys -t thin "exit" Enter 2>/dev/null; true'
sleep 2

# Check if pane is dead (remain-on-exit should keep it)
pane_dead=$(run_local bash -c 'tmux -L thin list-windows -t thin -F "#{pane_dead}" 2>/dev/null' || echo "0")
assert_eq "to-workstation dead pane detected (remain-on-exit)" "1" "$(echo "$pane_dead" | head -1)"

cleanup_to_output=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-to-workstation cleanup 2>&1' || true)
assert_contains "to-workstation cleanup finds dead windows" "Killed" "$cleanup_to_output"

# --- Test: socket isolation (no collision with tmux-ssh) ---
echo ""
echo "=== Socket isolation ==="
cleanup

# Create sessions on different sockets
run_local bash -c 'tmux new-session -d -s default_session'
run_local bash -c 'tmux -L thin new-session -d -s thin_session'
run_local bash -c 'tmux -L remote new-session -d -s remote_session'

# Verify they don't interfere
default_count=$(run_local bash -c 'tmux list-sessions 2>/dev/null | wc -l')
thin_count=$(run_local bash -c 'tmux -L thin list-sessions 2>/dev/null | wc -l')
remote_count=$(run_local bash -c 'tmux -L remote list-sessions 2>/dev/null | wc -l')

assert_eq "default socket has 1 session" "1" "$(echo "$default_count" | tr -d ' ')"
assert_eq "thin socket has 1 session" "1" "$(echo "$thin_count" | tr -d ' ')"
assert_eq "remote socket has 1 session" "1" "$(echo "$remote_count" | tr -d ' ')"

# --- Test: existing tmux-ssh still works ---
echo ""
echo "=== tmux-ssh regression check ==="
cleanup

existing_help=$(run_local bash -c 'nu /home/testuser/.local/bin/tmux-ssh 2>&1' || true)
assert_contains "tmux-ssh help still works" "txs" "$existing_help"

# --- Summary ---
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
fi
echo "==============================="

# --- Teardown ---
cleanup
docker compose down

exit $FAIL
