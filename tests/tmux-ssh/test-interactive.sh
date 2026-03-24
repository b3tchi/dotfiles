#!/usr/bin/env bash
# Interactive test helper for tmux-to-workstation
# Usage:
#   ./test-interactive.sh          Start fresh, land in fat tmux
#   ./test-interactive.sh fat      Reattach to fat tmux
#   ./test-interactive.sh thin     Reattach to thin tmux
#   ./test-interactive.sh down     Tear down containers
set -e
cd "$(dirname "$0")"

case "${1:-start}" in
    start)
        docker compose down -q 2>/dev/null
        docker compose up -d -q
        sleep 2
        docker compose exec -it -u testuser local bash -c 'tmux new-session -s fat'
        ;;
    fat)
        docker compose exec -it -u testuser local bash -c 'tmux attach -t fat'
        ;;
    thin)
        docker compose exec -it -u testuser local bash -c 'tmux -L thin attach'
        ;;
    down)
        docker compose down -q
        ;;
    *)
        echo "Usage: $0 [start|fat|thin|down]"
        ;;
esac
