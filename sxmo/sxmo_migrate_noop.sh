#!/bin/sh
# Skip sync mode - configs managed by rotz dotfiles
if [ "$1" = "sync" ]; then
    exit 0
fi
exec /usr/bin/sxmo_migrate.sh.orig "$@"
