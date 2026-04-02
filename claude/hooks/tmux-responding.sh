#!/bin/bash
[ -z "$TMUX" ] && exit 0
tmux set-option -pu @waiting
exit 0
