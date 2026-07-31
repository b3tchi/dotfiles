#!/usr/bin/env bash
# test-engine.sh — the ENGINE CAPABILITY seam shared by test-hotkeyd.sh and
# test-panic.sh (sp021 Task 1's `HOTKEYD_HAS_BINDS_FLAG`, wired at
# dotfiles-ylmp.15).
#
# WHY THIS FILE EXISTS. `dotfiles-2ats` parameterised the suites on
# HOTKEYD_BIN / HOTKEYD_PROC_PAT and then hit a wall it deliberately did not
# climb: a dozen stages inject a bind TABLE into a running daemon with
# `--binds <file.py>`, and the Go daemon has no such flag — its table is
# compiled in, the dwm config.h model (see cmd/hotkeyd/check.go). Those stages
# are not decoration; they are how the suite proves the validator is
# load-bearing, that startup refuses an invalid table by name, that a
# mods-less layer works, that a foreign grab is reported, that a keymap hole
# reads as DEGRADED, and that `on_exit` runs at shutdown. Dropping them for
# one engine would mean the two engines never passed the SAME contract, which
# is the whole point of the parity gate ([[us019]] AC).
#
# THE ANSWER: for an engine with no runtime table injection, a table fixture
# is a BINARY, not a file. `table_daemon` below builds one — the real
# cmd/hotkeyd, every line of it, with one extra source file overlaid in that
# assigns Binds/Layers in `init()`. Same code path, same startup validation,
# same argv shape; only the injection point moves from the command line to the
# linker. `go build -overlay` does this without touching the source tree.
#
# 2ats left three candidate shapes open (recompile-and-restart / a build-time
# fixture / skip with a named reason). This is the second, and it is chosen
# over the third for the reason the gate requirements state plainly: a stage
# that skips passes a run that never exercised what it claims. Nothing here
# can skip — a fixture that will not build returns non-zero and the caller
# FAILS.
#
# Sourced, never executed. Callers must have $HERE (the hotkeyd dir) and
# $HOTKEYD_BIN set before sourcing.
#
# HOTKEYD_HAS_BINDS_FLAG below is ONE of three vars a caller must set TOGETHER
# to select the Go engine — it says how to hand the daemon under test a bind
# table, but it says nothing about which engine hotkeyd.sh actually STARTS on
# the launcher-driven stages (test-hotkeyd.sh, test-panic.sh) or what pgrep
# pattern finds it. Those are separate seams (hotkeyd.sh's own engine_for(),
# and HOTKEYD_PROC_PAT), and all three must agree or the suite starts one
# engine while looking for another's argv:
#   HOTKEYD_ENGINE_DEFAULT=go HOTKEYD_BIN=path/to/hotkeyd \
#     HOTKEYD_PROC_PAT=hotkeyd HOTKEYD_HAS_BINDS_FLAG=0 ./test-hotkeyd.sh
# (same four vars for test-panic.sh). HOTKEYD_ENGINE_DEFAULT is read directly
# by hotkeyd.sh's engine_for() — not by this file — because the launcher
# resolves the engine per display, independent of how the fixture below hands
# it a table.

# 1 = the daemon under test accepts `--binds <file>` (hotkeyd.py). 0 = it does
# not (the Go build). Default 1 so the python path is byte-for-byte what it
# was before this file existed.
HOTKEYD_HAS_BINDS_FLAG="${HOTKEYD_HAS_BINDS_FLAG:-1}"

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
# Binds and Layers from an init() — running after their own initialisers, so
# it REPLACES the shipped table rather than racing it.
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

# table_daemon <py-table> <go-table> <scratch-dir> [name]
#
# Sets $TBL_BIN + $TBL_ARGS to a daemon invocation carrying that table, and
# returns non-zero if it could not be produced. Callers spell it
#
#     $TBL_BIN --display "$D" $TBL_ARGS
#
#   python: TBL_BIN=$HOTKEYD_BIN   TBL_ARGS="--binds <py-table>"
#   go:     TBL_BIN=<fixture>      TBL_ARGS=""
#
# THE TABLE ARGUMENT GOES AFTER --display, AND THAT IS LOAD-BEARING. Several
# pgrep sites in test-hotkeyd.sh match `<pat> --display :N` with no wildcard
# between the two, so a `--binds` that lands BEFORE --display makes a
# perfectly healthy daemon invisible to the suite — observed as five "daemon
# did not start" failures whose logs said "1 chords grabbed" (dotfiles-ylmp.15).
# Keeping the flag order identical to what the sites used before this seam
# existed is cheaper than widening five patterns.
#
# THE FIXTURE BINARY IS ALWAYS NAMED `hotkeyd`, in a directory of its own, for
# the other half of the same reason: HOTKEYD_PROC_PAT is matched as
# `<pat> .*--display`, i.e. with a SPACE after the pattern, so a binary called
# `hotkeyd-trap` would be invisible to every pgrep in both suites and to
# hotkeyd.sh's own daemon_pid(). The directory carries the name instead.
table_daemon() {
    _td_py="$1"
    _td_go="$2"
    _td_scratch="$3"
    _td_name="${4:-$(basename "$_td_go" .go)}"
    TBL_BIN=""
    TBL_ARGS=""
    if [ "$HOTKEYD_HAS_BINDS_FLAG" = 1 ]; then
        TBL_BIN="$HOTKEYD_BIN"
        TBL_ARGS="--binds $_td_py"
        return 0
    fi
    _td_out="$_td_scratch/$_td_name/hotkeyd"
    go_table_daemon "$_td_go" "$_td_out" || return 1
    TBL_BIN="$_td_out"
}
