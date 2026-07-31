#!/usr/bin/env bash
# test-engine.sh — the BIND-TABLE FIXTURE seam shared by test-hotkeyd.sh and
# test-panic.sh.
#
# WHY THIS FILE EXISTS. A dozen stages across those two suites need a daemon
# running a SPECIFIC bind table rather than the shipped one: a seeded duplicate
# chord, a layer that declares no exit_keys, a mods-less layer, a hold layer
# whose on_exit touches a file, a one-bind table whose i3 command names its own
# author. Those stages are not decoration — they are how the suites prove the
# validator is load-bearing, that startup refuses an invalid table BY NAME, that
# a foreign grab is reported, that a keymap hole reads as DEGRADED, and that
# `on_exit` really runs at shutdown.
#
# The daemon has no way to be handed a table at runtime, and deliberately never
# will: the table is COMPILED IN, the dwm config.h model (see
# cmd/hotkeyd/check.go). There is no `--binds` flag to point at a fixture file —
# the launcher refuses HOTKEYD_BINDS by name for the same reason.
#
# THE ANSWER: for an engine with no runtime table injection, a table fixture is
# a BINARY, not a file. `table_daemon` below builds one — the real cmd/hotkeyd,
# every line of it, with one extra source file overlaid in that assigns Binds
# and Layers in `init()`. Same code path, same startup validation, same argv
# shape; only the injection point moves from the command line to the linker.
# `go build -overlay` does this without touching the source tree.
#
# WHY IT SURVIVES THE PYTHON CUTOVER (dotfiles-ylmp.16). The seam was introduced
# at dotfiles-ylmp.15 to let two engines pass one contract, and the second engine
# is now gone — but the reason it is a BUILD rather than a flag was never about
# parity. It is about the surviving engine's own design, so the mechanism is
# unchanged; only the choice of engines it used to arbitrate is. The discipline
# it was written under is likewise unchanged and still load-bearing: the third
# shape considered back then was "skip the stage with a named reason", and a
# stage that skips passes a run that never exercised what it claims. Nothing
# here can skip — a fixture that will not build returns non-zero and the caller
# FAILS.
#
# Sourced, never executed. Callers must have $HERE (the hotkeyd dir) set before
# sourcing.

# The build caches, resolved NOW — at source time, which every caller reaches
# before it sandboxes $HOME. test-panic.sh runs its whole body under a
# throwaway HOME, and `go build` reads GOCACHE/GOMODCACHE out of it: left to
# default, every fixture build there would start from an empty cache in a
# directory that is deleted on exit. Empty is not wrong, just slow — but it is
# slow inside a stage that is already waiting on X servers and daemons.
_TE_GOCACHE="$(go env GOCACHE 2>/dev/null || true)"
_TE_GOMODCACHE="$(go env GOMODCACHE 2>/dev/null || true)"

# go_table_daemon <go-table-source> <out-binary>
#
# Builds ./cmd/hotkeyd with <go-table-source> overlaid in as an extra file in
# the package. That file must be `package main` and assign the package vars
# Binds and Layers from an init() — running after their own initialisers, so it
# REPLACES the shipped table rather than racing it.
#
# Returns 0 on success; on failure prints the compiler's own diagnosis to
# stderr and returns non-zero. Never falls back to the shipped binary: a
# fixture that silently became "the real table" would turn a negative case
# into a vacuous pass, which is the exact failure this whole seam exists to
# avoid.
go_table_daemon() {
    _gt_src="$1"
    _gt_out="$2"
    command -v go >/dev/null || {
        printf 'test-engine: go toolchain missing — cannot build a table fixture\n' >&2
        return 1
    }
    _gt_dir="$(dirname "$_gt_out")"
    mkdir -p "$_gt_dir"
    # The overlay maps a path that does NOT exist on disk into the package
    # directory. `go build` accepts that (it is how gopls feeds unsaved
    # buffers to the compiler) and the source tree is never written to — a
    # suite that left a .go file behind in cmd/hotkeyd could be committed by
    # accident, and would change what `rotz install hotkeyd` builds.
    _gt_ovl="$_gt_dir/overlay.json"
    printf '{"Replace":{"%s/cmd/hotkeyd/zz_table_fixture.go":"%s"}}' \
        "$HERE" "$_gt_src" > "$_gt_ovl"
    ( cd "$HERE" && env ${_TE_GOCACHE:+GOCACHE="$_TE_GOCACHE"} \
        ${_TE_GOMODCACHE:+GOMODCACHE="$_TE_GOMODCACHE"} \
        go build -overlay "$_gt_ovl" -o "$_gt_out" ./cmd/hotkeyd ) || return 1
    [ -x "$_gt_out" ]
}

# table_daemon <go-table> <scratch-dir> [name]
#
# Sets $TBL_BIN to a daemon invocation carrying that table, and returns non-zero
# if it could not be produced. Callers spell it
#
#     $TBL_BIN --display "$D"
#
# and nothing else: the fixture carries its table in the binary, so there is no
# trailing table argument to place. (Before dotfiles-ylmp.16 this function also
# set $TBL_ARGS, which held `--binds <file>` for the python engine and was empty
# for this one. With that engine deleted the variable was empty at every call
# site, so it is gone — an always-empty expansion in the middle of a daemon argv
# is a thing a reader has to prove is harmless.)
#
# THE FIXTURE BINARY IS ALWAYS NAMED `hotkeyd`, in a directory of its own, and
# that is load-bearing: HOTKEYD_PROC_PAT is matched as `<pat> .*--display`, i.e.
# with a SPACE after the pattern, so a binary called `hotkeyd-trap` would be
# invisible to every pgrep in both suites and to hotkeyd.sh's own daemon_pid().
# The directory carries the name instead.
table_daemon() {
    _td_go="$1"
    _td_scratch="$2"
    _td_name="${3:-$(basename "$_td_go" .go)}"
    TBL_BIN=""
    _td_out="$_td_scratch/$_td_name/hotkeyd"
    go_table_daemon "$_td_go" "$_td_out" || return 1
    TBL_BIN="$_td_out"
}
