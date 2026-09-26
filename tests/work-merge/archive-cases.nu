#!/usr/bin/env nu
# Shared-tree safety cases for archive-epic.sh (auctions-ycr9h, discovered
# from auctions-zyvfr).
#
# archive-epic.sh's finale edits AKM files directly in AKM_ROOT (the shared
# main worktree), commits them as one "feat(akm): archive $SP" commit, then
# calls `bd close` on the parent epic. Its ERR-trap rollback used to be
# `git reset --hard -q "$START_HEAD"` whenever HEAD had moved past
# START_HEAD — i.e. whenever the archive commit had already landed and
# `bd close` failed afterward. `--hard` wipes AKM_ROOT's working tree back to
# START_HEAD wholesale, destroying any uncommitted edit another session made
# there in the meantime — the same hazard land-bd-task.sh hit and fixed
# (auctions-zyvfr). These cases pin the replacement contract:
#
#   - HEAD still at our own archive commit → rollback via `reset --merge`,
#     which keeps unrelated uncommitted edits and HEAD ends back at
#     START_HEAD;
#   - another session commits on top of ours while `bd close` is in flight →
#     `git revert` the archive commit rather than reset past the commit that
#     followed it;
#   - neither undo is safe (a live uncommitted edit conflicts with the path
#     being reset) → stop loudly at exit 4 with a bd note, never `--hard`.

use harness.nu *

def head-sha [root: string]: nothing -> string {
    git -C $root rev-parse HEAD | str trim
}

def read-file [root: string, rel: string]: nothing -> string {
    open --raw ($root | path join $rel)
}

def head-subject [root: string]: nothing -> string {
    git -C $root log -1 --format=%s | str trim
}

let cases = [
    # ── The incident: unrelated WIP must survive a failing `bd close` ───────
    (run-case "archive-rollback/unrelated-dirty-survives-failing-close" {
        let root = (make-akm-repo "arwip" "sp900" "ft900")
        let bin = (make-archive-bd-stub $root 1)
        let pre = (head-sha $root)

        # Another session's uncommitted state in the shared tree: a tracked
        # edit and an untracked file, both outside anything this finale
        # touches.
        "seed\nother session WIP\n" | save -f ($root | path join "README.md")
        "brand new notes\n" | save -f ($root | path join "notes.md")

        let out = (run-archive $root $bin "sp900" "bd-epic900")

        assert-eq $out.exit_code 1 $"a failing bd close must reject: ($out.stderr)"
        assert-eq (head-sha $root) $pre "HEAD must be back at the pre-archive commit:"
        # The load-bearing assertions — before the fix both were wiped by
        # `reset --hard`.
        assert-eq (read-file $root "README.md") "seed\nother session WIP\n" "unstaged WIP was destroyed:"
        assert-eq (read-file $root "notes.md") "brand new notes\n" "untracked WIP was destroyed:"
        # The archive mutation itself must be fully undone.
        assert-true (not ($root | path join "docs/notes/archive/spec/sp900.md" | path exists)) "archived copy must not remain"
        assert-str-contains (read-file $root "docs/notes/spec/sp900.md") "status: ready" "spec must be restored to ready:"
        assert-str-contains (read-file $root "docs/notes/ft900.md") "status: proposed" "feature must be restored to proposed:"
        assert-str-contains (read-file $root "docs/board.md") "[[sp900]]" "board entry must be restored:"
    })

    (run-case "archive-land/unrelated-dirty-survives-successful-finale" {
        let root = (make-akm-repo "arok" "sp901" "ft901")
        let bin = (make-archive-bd-stub $root 0)
        "other session WIP\n" | save -f ($root | path join "other.yaml")

        let out = (run-archive $root $bin "sp901" "bd-epic901")

        assert-eq $out.exit_code 0 $"a successful finale must not be blocked by unrelated dirt: ($out.stderr)"
        assert-str-contains (read-file $root "docs/notes/archive/spec/sp901.md") "status: done" "the finale did not land:"
        assert-eq (read-file $root "other.yaml") "other session WIP\n" "unrelated WIP was lost:"
    })

    # ── Concurrent commit while `bd close` runs → revert, not reset ─────────
    (run-case "archive-rollback/concurrent-commit-during-close-is-reverted-not-reset" {
        let root = (make-akm-repo "arconc" "sp902" "ft902")
        # The side effect stands in for another session's own land landing a
        # commit in AKM_ROOT between our archive commit and `bd close`
        # returning — then `bd close` itself still fails.
        let side_effect = $"echo concurrent > '($root)/concurrent.txt' && git -C '($root)' add concurrent.txt && git -C '($root)' -c user.email=t@e.invalid -c user.name=t commit -q -m concurrent"
        let bin = (make-archive-bd-stub $root 1 $side_effect)

        let out = (run-archive $root $bin "sp902" "bd-epic902")

        assert-eq $out.exit_code 1 $"a failing bd close must reject: ($out.stderr)"
        assert-eq (read-file $root "concurrent.txt") "concurrent\n" "the concurrent commit was destroyed:"
        let subjects = (git -C $root log --format=%s -3 | lines)
        assert-str-contains ($subjects | str join "|") "concurrent" "the concurrent commit left history:"
        assert-str-contains ($subjects | first) "Revert" "the archive commit should be reverted:"
        assert-str-contains (read-file $root "docs/notes/spec/sp902.md") "status: ready" "spec must be restored to ready:"
        assert-true (not ($root | path join "docs/notes/archive/spec/sp902.md" | path exists)) "archived copy must not remain"
    })

    # ── Unsafe undo stops loudly, never escalates to --hard ─────────────────
    (run-case "archive-rollback/unsafe-undo-stops-at-exit-4-instead-of-hard-reset" {
        let root = (make-akm-repo "arunsafe" "sp903" "ft903")
        # While `bd close` is "in flight", someone live-edits the very file
        # the archive commit just created. `reset --merge` cannot undo the
        # commit without clobbering that edit, so it must refuse — and the
        # script must stop there, not reach for --hard.
        let side_effect = $"echo 'live edit' > '($root)/docs/notes/archive/spec/sp903.md'"
        let bin = (make-archive-bd-stub $root 1 $side_effect)

        let out = (run-archive $root $bin "sp903" "bd-epic903")
        let calls = (read-log $root "bd-calls.log" | str join "\n")

        assert-eq $out.exit_code 4 "an unsafe rollback must stop with exit 4:"
        assert-eq (read-file $root "docs/notes/archive/spec/sp903.md") "live edit\n" "the live edit was destroyed:"
        assert-str-contains $out.stderr "ROLLBACK INCOMPLETE" "the stop must be loud:"
        assert-str-contains $calls "ROLLBACK INCOMPLETE" "the bd note must say the archive commit is still there:"
        # The archive commit itself must still be HEAD — no reset, no revert.
        assert-eq (head-subject $root) "feat(akm): archive sp903" "HEAD must still be the archive commit, untouched:"
    })
]

$cases | to json
