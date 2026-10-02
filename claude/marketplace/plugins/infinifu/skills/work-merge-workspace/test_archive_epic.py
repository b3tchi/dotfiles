#!/usr/bin/env python3
"""Behavior tests for work-merge archive-epic.sh."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SKILLS_DIR = Path(__file__).resolve().parents[1]
SCRIPT = SKILLS_DIR / "work-merge" / "scripts" / "archive-epic.sh"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def frontmatter(alias: str, status: str, kind: str = "Note", links: str = "[[product]]") -> str:
    return f"""---
aliases:
  - {alias}
status: {status}
created: 2026-01-01
---
# {kind} {links}

## body
content

---

Index: [[product]]
"""


def init_workspace(root: Path) -> Path:
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
    write(root / "docs/board.md", "# Board\n\n## ready\n\n- [[sp001|ship thing]]\n")
    write(root / "docs/archive.md", "# Archive\n\n## done\n")
    write(root / "docs/notes/us001.md", frontmatter("story", "ready", "Story"))
    write(root / "docs/notes/im001.md", frontmatter("implementation", "proposed", "Implementation"))
    write(root / "docs/notes/ft001.md", frontmatter("feature", "proposed", "Feature"))
    # Already-shipped artifacts, for the consumed-story and feature-refresh shapes.
    write(root / "docs/notes/us002.md", frontmatter("shipped story", "done", "Story"))
    write(root / "docs/notes/im002.md", frontmatter("shipped implementation", "accepted", "Implementation"))
    write(root / "docs/notes/ft002.md", frontmatter("shipped feature", "accepted", "Feature"))
    write(root / "docs/notes/ft003.md", frontmatter("stable feature", "stable", "Feature"))
    write(
        root / "bd",
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [ \"$1\" = close ]; then printf 'close %s\\n' \"$2\" >> bd.log; fi\n"
        "if [ \"${BD_FAIL_CLOSE:-0}\" = 1 ] && [ \"$1\" = close ]; then exit 42; fi\n"
        "exit 0\n",
    )
    (root / "bd").chmod(0o755)
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "seed"], cwd=root, check=True)
    return root


def run_archive(root: Path, *args: str, fail_close: bool = False) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PATH"] = f"{root}:{env['PATH']}"
    if fail_close:
        env["BD_FAIL_CLOSE"] = "1"
    return subprocess.run(
        ["bash", str(SCRIPT), *args, str(root)],
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def status(path: Path) -> str:
    for line in path.read_text().splitlines():
        if line.startswith("status: "):
            return line.split(": ", 1)[1]
    raise AssertionError(f"no status in {path}")


class ArchiveEpicTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = init_workspace(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def docs_snapshot(self) -> dict[Path, str]:
        return {p.relative_to(self.root): p.read_text() for p in (self.root / "docs").rglob("*.md")}

    def write_spec(self, alias: str, body: str) -> None:
        write(
            self.root / "docs/notes/spec/sp001.md",
            frontmatter(alias, "ready", "Spec", "[[cat001]] [[board]]")
            .replace("## body\ncontent", body)
            .replace("Index: [[product]]", "Index: [[board]]"),
        )

    def commit_spec(self, message: str) -> None:
        subprocess.run(["git", "add", "docs/notes/spec/sp001.md"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", message], cwd=self.root, check=True)

    def test_feature_only_finale_accepts_feature_without_story_or_implementation(self) -> None:
        self.write_spec("ship feature", "## problem\nShip proposed [[ft001]] without a story-backed implementation.")
        self.commit_spec("feature spec")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/ft001.md"), "accepted")
        self.assertFalse((self.root / "docs/notes/spec/sp001.md").exists())
        archived_spec = self.root / "docs/notes/archive/spec/sp001.md"
        self.assertEqual(status(archived_spec), "done")
        self.assertIn("Index: [[archive]]", archived_spec.read_text())
        self.assertNotIn("sp001", (self.root / "docs/board.md").read_text())
        self.assertIn("[[sp001|ship thing]]", (self.root / "docs/archive.md").read_text())
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "ready")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "proposed")

    def test_story_backed_finale_still_flips_story_and_implementation(self) -> None:
        self.write_spec("ship story", "## solves\n[[us001]]\n\n## implements\n[[im001]]")
        self.commit_spec("story spec")

        result = run_archive(self.root, "sp001", "us001", "im001", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "done")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/ft001.md"), "proposed")
        self.assertEqual(status(self.root / "docs/notes/archive/spec/sp001.md"), "done")

    def test_feature_add_spec_citing_an_unrelated_story_or_implementation(self) -> None:
        # A feature-add spec routinely names an im###/us### in prose to say it is
        # NOT a dependency (the survey discipline asks for exactly that). Those
        # mentions carry no lineage: only ## solves / ## implements do.
        self.write_spec(
            "ship feature",
            "## problem\nShip proposed [[ft001]]. [[im001]] and its story [[us001]]\n"
            "solve a different problem and are surveyed non-dependencies.",
        )
        self.commit_spec("feature spec citing a non-dependency")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/ft001.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "ready")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "proposed")
        self.assertEqual(status(self.root / "docs/notes/archive/spec/sp001.md"), "done")

    def test_blank_lineage_args_still_infer_from_solves_and_implements(self) -> None:
        # Inference is not removed, only narrowed to the role-bearing sections.
        self.write_spec(
            "ship story",
            "## solves\n[[us001]]\n\n## implements\n[[im001]]\n\n"
            "## problem\nAlso mentions [[ft001]] as a consumed feature.",
        )
        self.commit_spec("story spec")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "done")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "accepted")

    def test_ambiguous_lineage_fails_before_any_archive_mutation(self) -> None:
        self.write_spec("ambiguous", "## solves\n[[us001]]\n\n## problem\nMissing implementation and feature deliverable.")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous", (result.stderr + result.stdout).lower())
        self.assertEqual(self.docs_snapshot(), before)

    def test_failure_during_archive_rolls_back_file_mutations(self) -> None:
        self.write_spec("ship feature", "## problem\nShip proposed [[ft001]].")
        self.commit_spec("feature spec")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1", fail_close=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rolled back", (result.stderr + result.stdout).lower())
        self.assertEqual(self.docs_snapshot(), before)
        self.assertFalse((self.root / "docs/notes/archive/spec/sp001.md").exists())

    def test_commit_failure_rolls_back_files_without_closing_epic(self) -> None:
        self.write_spec("ship feature", "## problem\nShip proposed [[ft001]].")
        self.commit_spec("feature spec")
        before = self.docs_snapshot()
        hook = self.root / ".git/hooks/pre-commit"
        hook.write_text("#!/usr/bin/env bash\necho forced commit failure >&2\nexit 43\n")
        hook.chmod(0o755)

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rolled back", (result.stderr + result.stdout).lower())
        self.assertEqual(self.docs_snapshot(), before)
        self.assertFalse((self.root / "docs/notes/archive/spec/sp001.md").exists())
        self.assertFalse((self.root / "bd.log").exists(), "bd close must not run before a successful commit")

    # ---- feature-refresh shape -------------------------------------------
    # A spec that widens an ALREADY-ACCEPTED ft### instead of minting a new
    # one. Nothing to flip: the feature was accepted before this spec and
    # stays accepted after it. spec-retro rewrites its refreshed body.

    def test_feature_refresh_finale_archives_without_flipping_the_feature(self) -> None:
        self.write_spec(
            "widen feature",
            "## extends [[ft002]]\n\n## problem\n[[ft002]] gets a body refresh with a widened\n"
            "## api_surface, not a new ft###. One capability, wider surface.",
        )
        self.commit_spec("feature-refresh spec")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        # The refreshed feature is asserted to exist and is NOT mutated.
        self.assertEqual(status(self.root / "docs/notes/ft002.md"), "accepted")
        # Everything else the finale owes still happens.
        archived_spec = self.root / "docs/notes/archive/spec/sp001.md"
        self.assertFalse((self.root / "docs/notes/spec/sp001.md").exists())
        self.assertEqual(status(archived_spec), "done")
        self.assertIn("Index: [[archive]]", archived_spec.read_text())
        self.assertNotIn("sp001", (self.root / "docs/board.md").read_text())
        self.assertIn("[[sp001|ship thing]]", (self.root / "docs/archive.md").read_text())
        self.assertIn("close epic-1", (self.root / "bd.log").read_text())
        # No unrelated lineage touched.
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "ready")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "proposed")
        self.assertEqual(status(self.root / "docs/notes/ft001.md"), "proposed")

    def test_feature_refresh_accepts_a_stable_feature_too(self) -> None:
        self.write_spec("widen stable feature", "## extends [[ft003]]\n\n## problem\nWiden it.")
        self.commit_spec("feature-refresh spec on a stable feature")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/ft003.md"), "stable")
        self.assertEqual(status(self.root / "docs/notes/archive/spec/sp001.md"), "done")

    def test_accepted_feature_cited_only_in_prose_still_fails_closed(self) -> None:
        # THE TRAP. A feature-add spec whose ft### was never minted as
        # `proposed` is textually indistinguishable from a refresh if you only
        # look at citations. Treating "an accepted ft### is cited" as a refresh
        # would archive it silently and leave a feature permanently
        # un-accepted. Only an explicit `## extends` declaration classifies.
        self.write_spec("forgot to mint", "## problem\nShip the capability described alongside [[ft002]].")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous", (result.stderr + result.stdout).lower())
        self.assertEqual(self.docs_snapshot(), before)
        self.assertEqual(status(self.root / "docs/notes/ft002.md"), "accepted")
        self.assertFalse((self.root / "bd.log").exists())

    def test_extends_declaring_a_proposed_feature_still_takes_the_feature_add_path(self) -> None:
        # `## extends` on a not-yet-accepted ft### is the ordinary feature-add
        # shape: the declaration names the deliverable, and it still flips.
        self.write_spec("mint feature", "## extends [[ft001]]\n\n## problem\nShip it.")
        self.commit_spec("feature-add spec declaring its deliverable")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/ft001.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/archive/spec/sp001.md"), "done")

    def test_extends_declaring_two_features_is_ambiguous(self) -> None:
        self.write_spec("widen two", "## extends [[ft002]] [[ft003]]\n\n## problem\nWiden both.")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous", (result.stderr + result.stdout).lower())
        self.assertEqual(self.docs_snapshot(), before)

    def test_extends_declaring_a_missing_feature_fails_before_mutation(self) -> None:
        self.write_spec("widen ghost", "## extends [[ft099]]\n\n## problem\nWiden a feature that is not there.")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ft099", result.stderr + result.stdout)
        self.assertEqual(self.docs_snapshot(), before)

    def test_prose_citation_of_an_accepted_feature_does_not_block_a_story_backed_finale(self) -> None:
        # Regression guard for the new extractor: accepted ft### links outside
        # `## extends` stay pure prose, exactly as adr0026 requires.
        self.write_spec(
            "ship story",
            "## solves\n[[us001]]\n\n## implements\n[[im001]]\n\n"
            "## problem\n[[ft002]] is a surveyed non-dependency.",
        )
        self.commit_spec("story spec citing an accepted feature")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "done")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/ft002.md"), "accepted")

    # ---- story-refresh shape ---------------------------------------------
    # A spec that delivers one or more stories by refreshing implementations
    # that were ALREADY accepted under earlier specs. The stories flip
    # ready → done; the refreshed im### stay accepted (spec-retro rewrites
    # their bodies). Recognised ONLY from an explicit `## refreshes` section.

    def seed_refresh_lineage(self) -> None:
        write(self.root / "docs/notes/us003.md", frontmatter("second story", "ready", "Story"))
        write(self.root / "docs/notes/im004.md", frontmatter("other shipped impl", "accepted", "Implementation"))
        write(self.root / "docs/notes/im005.md", frontmatter("stable impl", "stable", "Implementation"))
        subprocess.run(["git", "add", "docs/notes"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "seed refresh lineage"], cwd=self.root, check=True)

    def test_story_refresh_flips_every_solved_story_and_no_implementation(self) -> None:
        self.seed_refresh_lineage()
        self.write_spec(
            "refresh impls",
            "## solves\n[[us001|first]] [[us003|second]]\n\n"
            "## refreshes\n[[im002]] [[im004]] [[im005]]\n\n"
            "## problem\nWiden shipped behaviour; [[im001]] is a surveyed non-dependency.",
        )
        self.commit_spec("story-refresh spec")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "done")
        self.assertEqual(status(self.root / "docs/notes/us003.md"), "done")
        self.assertEqual(status(self.root / "docs/notes/im002.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/im004.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/im005.md"), "stable")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "proposed")
        self.assertEqual(status(self.root / "docs/notes/archive/spec/sp001.md"), "done")
        self.assertNotIn("sp001", (self.root / "docs/board.md").read_text())
        self.assertIn("close epic-1", (self.root / "bd.log").read_text())
        self.assertIn("us001 → done", result.stdout)
        self.assertIn("us003 → done", result.stdout)
        self.assertIn("refreshed", result.stdout)
        # Story flips land in the archive commit, not left dirty.
        dirty = subprocess.run(["git", "status", "--porcelain", "docs"], cwd=self.root,
                               text=True, stdout=subprocess.PIPE, check=True).stdout
        self.assertEqual(dirty, "")

    def test_story_refresh_rejects_a_proposed_implementation(self) -> None:
        # A proposed im### is the owned shape and belongs under ## implements.
        self.write_spec("refresh proposed", "## solves\n[[us001]]\n\n## refreshes\n[[im001]]")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("im001", result.stderr)
        self.assertEqual(self.docs_snapshot(), before)
        self.assertFalse((self.root / "bd.log").exists())

    def test_story_refresh_rejects_a_story_that_is_not_ready(self) -> None:
        self.write_spec("refresh done story", "## solves\n[[us001]] [[us002]]\n\n## refreshes\n[[im002]]")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("us002", result.stderr)
        self.assertEqual(self.docs_snapshot(), before)

    def test_story_refresh_rejects_a_missing_implementation(self) -> None:
        self.write_spec("refresh ghost", "## solves\n[[us001]]\n\n## refreshes\n[[im099]]")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("im099", result.stderr)
        self.assertEqual(self.docs_snapshot(), before)

    def test_refreshes_together_with_implements_is_ambiguous(self) -> None:
        self.write_spec(
            "both",
            "## solves\n[[us001]]\n\n## implements\n[[im001]]\n\n## refreshes\n[[im002]]",
        )
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous", result.stderr.lower())
        self.assertEqual(self.docs_snapshot(), before)

    def test_refreshes_without_a_solved_story_is_ambiguous(self) -> None:
        self.write_spec("no story", "## refreshes\n[[im002]]\n\n## problem\nNo story.")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous", result.stderr.lower())
        self.assertEqual(self.docs_snapshot(), before)

    def test_story_refresh_rolls_back_every_story_flip_on_failure(self) -> None:
        self.seed_refresh_lineage()
        self.write_spec("refresh impls", "## solves\n[[us001]] [[us003]]\n\n## refreshes\n[[im002]]")
        self.commit_spec("story-refresh spec")
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1", fail_close=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rolled back", (result.stderr + result.stdout).lower())
        self.assertEqual(self.docs_snapshot(), before)

    def test_solves_two_stories_without_refreshes_still_fails_closed(self) -> None:
        # The sp011 shape before the fix: multi-story ## solves, accepted ims
        # only cited in prose. Without the declaration it must stay loud.
        self.write_spec(
            "undeclared refresh",
            "## solves\n[[us001]] [[us003]]\n\n## problem\nRefreshes [[im002]] in prose only.",
        )
        before = self.docs_snapshot()

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refreshes", result.stderr)
        self.assertEqual(self.docs_snapshot(), before)

    # ---- pre-existing shapes, unchanged ----------------------------------

    def test_story_backed_consumed_mode_flips_nothing_upstream(self) -> None:
        self.write_spec("consume shipped story", "## solves\n[[us002]]\n\n## implements\n[[im002]]")
        self.commit_spec("consuming spec")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/us002.md"), "done")
        self.assertEqual(status(self.root / "docs/notes/im002.md"), "accepted")
        self.assertIn("consumed", result.stdout)
        self.assertEqual(status(self.root / "docs/notes/archive/spec/sp001.md"), "done")

    def test_mixed_finale_flips_story_implementation_and_proposed_feature(self) -> None:
        self.write_spec(
            "ship story and feature",
            "## solves\n[[us001]]\n\n## implements\n[[im001]]\n\n## problem\nAlso mints [[ft001]].",
        )
        self.commit_spec("mixed spec")

        result = run_archive(self.root, "sp001", "", "", "epic-1")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(status(self.root / "docs/notes/us001.md"), "done")
        self.assertEqual(status(self.root / "docs/notes/im001.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/ft001.md"), "accepted")
        self.assertEqual(status(self.root / "docs/notes/archive/spec/sp001.md"), "done")


if __name__ == "__main__":
    unittest.main(verbosity=2)
