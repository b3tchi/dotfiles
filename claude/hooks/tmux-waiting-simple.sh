#!/bin/bash
[ -z "$TMUX" ] && exit 0
tmux set-option -p @waiting 1
exit 0
