#!/usr/bin/env bash
# archive-epic.sh — last-child epic finale (local only).
#
# Runs when the just-closed bd task was the last open child of its parent epic.
# Flips AKM lifecycle statuses (us → done, im → accepted, sp → done), moves the
# sp### entry from board.md → archive.md, closes the bd epic, and commits the
# whole flip as one "feat(akm): archive sp<NNN>" commit on $AKM_ROOT.
#
# No push — spec-retro handles remote sync.
#
# Usage: archive-epic.sh <sp-id> <us-id> <im-id> <epic-bd-id> [AKM_ROOT]
#   sp-id  — e.g. sp012  (without `.md`)
#   us-id  — e.g. us007
#   im-id  — e.g. im013
#   epic-bd-id — the bd epic id (e.g. bd-AAAA)
#   AKM_ROOT defaults to $(akm-root) or cwd.
#
# Each AKM zettel is a markdown file with YAML frontmatter; this script
# rewrites the `status:` line in-place using sed. The sp### footer line
# `Index: [[board]]` flips to `Index: [[archive]]`.

set -euo pipefail

SP="${1:?missing sp id, e.g. archive-epic.sh sp012 us007 im013 bd-XXXX}"
US="${2:?missing us id}"
IM="${3:?missing im id}"
EPIC="${4:?missing epic bd id}"
AKM_ROOT="${5:-${AKM_ROOT:-$(akm-root 2>/dev/null || pwd)}}"

SP_FILE="$AKM_ROOT/docs/notes/spec/$SP.md"
US_FILE="$AKM_ROOT/docs/notes/$US.md"
IM_FILE="$AKM_ROOT/docs/notes/$IM.md"
BOARD="$AKM_ROOT/docs/board.md"
ARCHIVE="$AKM_ROOT/docs/archive.md"

for f in "$SP_FILE" "$US_FILE" "$IM_FILE" "$BOARD" "$ARCHIVE"; do
  [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done

# Flip frontmatter status fields. The first `status:` line in each file is in
# the YAML block at the top — limit sed to lines 1–20 to avoid hitting body.
flip_status () {
  local file="$1" from="$2" to="$3"
  sed -i "1,20{s/^status: ${from}\$/status: ${to}/;}" "$file"
}

flip_status "$US_FILE" "ready"    "done"
flip_status "$IM_FILE" "proposed" "accepted"
flip_status "$SP_FILE" "ready"    "done"

# sp### footer Index flip (whole file — footer is usually last line)
sed -i 's/^Index: \[\[board\]\]$/Index: [[archive]]/' "$SP_FILE"

# Physically relocate the delivered spec into the archive mirror
# (docs/notes/archive/spec/) so spec/ holds only active specs. akm's
# id-allocation + alias lookup span active + archive (see `type_dirs`), so the
# id stays reserved and the zettel stays findable after the move. Done after the
# in-place edits above; git mv carries the working-tree changes to the new path.
SP_ARCHIVE="$AKM_ROOT/docs/notes/archive/spec/$SP.md"
mkdir -p "$(dirname "$SP_ARCHIVE")"
git -C "$AKM_ROOT" mv "$SP_FILE" "$SP_ARCHIVE"

# Board → archive move. Match `[[sp###` to allow `[[sp012|title]]` aliases.
SP_LINE="$(grep -E "\[\[$SP(\\||\\])" "$BOARD" || true)"
if [ -n "$SP_LINE" ]; then
  # Remove from board (delete matching lines)
  sed -i "/\[\[$SP\(|\|\]\)/d" "$BOARD"
  # Append to archive under ## done
  if grep -q '^## done' "$ARCHIVE"; then
    awk -v line="$SP_LINE" '
      {print}
      /^## done$/ && !done {print ""; print line; done=1}
    ' "$ARCHIVE" > "$ARCHIVE.tmp" && mv "$ARCHIVE.tmp" "$ARCHIVE"
  else
    printf '\n## done\n\n%s\n' "$SP_LINE" >> "$ARCHIVE"
  fi
else
  echo "WARN: $SP not found in $BOARD — board may have been hand-edited" >&2
fi

# Close the bd epic
bd close "$EPIC" --reason "Merged via $SP. All child tasks closed by work-audit." >/dev/null

# Commit the lifecycle flip as one AKM admin commit on main. The git mv above
# already staged the spec rename (old path deleted, new path added); re-add the
# archive path so its in-place status/footer edits are staged too.
git -C "$AKM_ROOT" add \
  "$SP_ARCHIVE" "$US_FILE" "$IM_FILE" "$BOARD" "$ARCHIVE"
git -C "$AKM_ROOT" commit -m "feat(akm): archive $SP"

echo "---"
echo "Archived: $SP → done ($SP_ARCHIVE), $US → done, $IM → accepted. Board → archive. Epic $EPIC closed."
echo "Next: run spec-retro for $SP to refresh AKM graph + push to remote."
