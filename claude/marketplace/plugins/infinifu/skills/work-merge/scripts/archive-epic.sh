#!/usr/bin/env bash
# archive-epic.sh — last-child epic finale (local only).
#
# Runs when the just-closed bd task was the last open child of its parent epic.
# Flips AKM lifecycle statuses, moves the sp### entry from board.md →
# archive.md, closes the bd epic, and commits the whole flip as one
# "feat(akm): archive sp<NNN>" commit on $AKM_ROOT.
#
# Story-backed finale:
#   archive-epic.sh <sp-id> <us-id> <im-id> <epic-bd-id> [AKM_ROOT]
# Feature-add finale:
#   archive-epic.sh <sp-id> "" "" <epic-bd-id> [AKM_ROOT]
#
# For feature-add specs, the proposed ft### deliverable is resolved from the
# spec body. Mixed specs with both story-backed and proposed-feature lineage flip
# all applicable artifacts. Ambiguous shapes fail before any file mutation.
#
# No push — spec-retro handles remote sync.

set -euo pipefail

SP="${1:?missing sp id, e.g. archive-epic.sh sp012 us007 im013 bd-XXXX}"
US="${2:-}"
IM="${3:-}"
EPIC="${4:?missing epic bd id}"
AKM_ROOT="${5:-${AKM_ROOT:-$(akm-root 2>/dev/null || pwd)}}"

SP_FILE="$AKM_ROOT/docs/notes/spec/$SP.md"
BOARD="$AKM_ROOT/docs/board.md"
ARCHIVE="$AKM_ROOT/docs/archive.md"
SP_ARCHIVE="$AKM_ROOT/docs/notes/archive/spec/$SP.md"

for f in "$SP_FILE" "$BOARD" "$ARCHIVE"; do
  [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done
[ ! -e "$SP_ARCHIVE" ] || { echo "ERROR: archive target already exists: $SP_ARCHIVE" >&2; exit 1; }

# Lineage is declared by the spec's ## solves (story) and ## implements
# (implementation) sections — not by any mention of the id. A spec routinely
# cites an unrelated im###/us### in prose to record it as a surveyed
# NON-dependency, and reading the first match anywhere in the body turned such
# a citation into lineage: a feature-add spec then archived as story-backed and
# flipped somebody else's story to done. Scope the scan to the owning section.
extract_section_link () {
  local section="$1" prefix="$2" file="$3"
  awk -v section="## $section" '
    $0 == section { in_section = 1; next }
    /^## / { in_section = 0 }
    in_section { print }
  ' "$file" | grep -oE "\[\[$prefix[0-9]+" | head -1 | sed 's/^\[\[//' || true
}

status_of () {
  local file="$1"
  sed -n '1,20s/^status: //p' "$file" | head -1
}

require_status () {
  local file="$1" want="$2"
  local got
  got="$(status_of "$file")"
  [ "$got" = "$want" ] || {
    echo "ERROR: $file must have status: $want before archive finale (got: ${got:-missing})" >&2
    exit 1
  }
}

# Allow callers to pass story lineage explicitly, but infer it from the spec's
# declared lineage sections when the slots are blank.
SPEC_US="$(extract_section_link solves us "$SP_FILE")"
SPEC_IM="$(extract_section_link implements im "$SP_FILE")"
US="${US:-$SPEC_US}"
IM="${IM:-$SPEC_IM}"

HAS_STORY=0
if [ -n "$US" ] || [ -n "$IM" ]; then
  if [ -z "$US" ] || [ -z "$IM" ]; then
    echo "ERROR: ambiguous lifecycle shape for $SP: story-backed finale needs both us### and im###" >&2
    exit 1
  fi
  HAS_STORY=1
fi

# A feature-add deliverable is the unique proposed ft### referenced by the spec
# or, as a fallback for older epics, the epic notes/design. Stable/accepted ft###
# links in story-backed specs are consumed features, not deliverables to flip.
proposed_ft_links () {
  while read -r ft; do
    [ -n "$ft" ] || continue
    ft_file="$AKM_ROOT/docs/notes/$ft.md"
    [ -f "$ft_file" ] || continue
    [ "$(status_of "$ft_file")" = "proposed" ] && printf '%s\n' "$ft"
  done | sort -u
}
mapfile -t PROPOSED_FTS < <(
  { grep -oE '\[\[ft[0-9]+' "$SP_FILE" | sed 's/^\[\[//'; } | proposed_ft_links
)
if [ "${#PROPOSED_FTS[@]}" -eq 0 ]; then
  mapfile -t PROPOSED_FTS < <(
    { bd show "$EPIC" 2>/dev/null || true; } | grep -oE 'ft[0-9]+' | proposed_ft_links
  )
fi

HAS_FEATURE=0
FT=""
if [ "${#PROPOSED_FTS[@]}" -eq 1 ]; then
  HAS_FEATURE=1
  FT="${PROPOSED_FTS[0]}"
elif [ "${#PROPOSED_FTS[@]}" -gt 1 ]; then
  echo "ERROR: ambiguous lifecycle shape for $SP: multiple proposed ft### deliverables: ${PROPOSED_FTS[*]}" >&2
  exit 1
fi

if [ "$HAS_STORY" -eq 0 ] && [ "$HAS_FEATURE" -eq 0 ]; then
  echo "ERROR: ambiguous lifecycle shape for $SP: no complete story-backed lineage and no unique proposed ft### deliverable" >&2
  exit 1
fi

require_status "$SP_FILE" "ready"

TOUCH_PATHS=("$SP_FILE" "$BOARD" "$ARCHIVE")
if [ "$HAS_STORY" -eq 1 ]; then
  US_FILE="$AKM_ROOT/docs/notes/$US.md"
  IM_FILE="$AKM_ROOT/docs/notes/$IM.md"
  for f in "$US_FILE" "$IM_FILE"; do
    [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
  done
  require_status "$US_FILE" "ready"
  require_status "$IM_FILE" "proposed"
  TOUCH_PATHS+=("$US_FILE" "$IM_FILE")
fi
if [ "$HAS_FEATURE" -eq 1 ]; then
  FT_FILE="$AKM_ROOT/docs/notes/$FT.md"
  [ -f "$FT_FILE" ] || { echo "ERROR: missing $FT_FILE" >&2; exit 1; }
  require_status "$FT_FILE" "proposed"
  TOUCH_PATHS+=("$FT_FILE")
fi

START_HEAD="$(git -C "$AKM_ROOT" rev-parse HEAD)"
BACKUP_DIR="$(mktemp -d)"
rollback () {
  local code=$?
  trap - ERR
  if [ "$(git -C "$AKM_ROOT" rev-parse HEAD 2>/dev/null || true)" != "$START_HEAD" ]; then
    git -C "$AKM_ROOT" reset --hard -q "$START_HEAD" 2>/dev/null || true
  fi
  for path in "${TOUCH_PATHS[@]}"; do
    rel="${path#$AKM_ROOT/}"
    if [ -f "$BACKUP_DIR/$rel" ]; then
      mkdir -p "$(dirname "$path")"
      cp -p "$BACKUP_DIR/$rel" "$path"
    fi
  done
  rm -f "$SP_ARCHIVE"
  git -C "$AKM_ROOT" reset -q HEAD -- "${TOUCH_PATHS[@]}" "$SP_ARCHIVE" 2>/dev/null || true
  rm -rf "$BACKUP_DIR"
  echo "ERROR: archive finale failed; rolled back file mutations for $SP" >&2
  exit "$code"
}
trap rollback ERR

for path in "${TOUCH_PATHS[@]}"; do
  rel="${path#$AKM_ROOT/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  cp -p "$path" "$BACKUP_DIR/$rel"
done

# Flip frontmatter status fields. The first `status:` line in each file is in
# the YAML block at the top — limit sed to lines 1–20 to avoid hitting body.
flip_status () {
  local file="$1" from="$2" to="$3"
  sed -i "1,20{s/^status: ${from}\$/status: ${to}/;}" "$file"
}

[ "$HAS_STORY" -eq 0 ] || {
  flip_status "$US_FILE" "ready" "done"
  flip_status "$IM_FILE" "proposed" "accepted"
}
[ "$HAS_FEATURE" -eq 0 ] || flip_status "$FT_FILE" "proposed" "accepted"
flip_status "$SP_FILE" "ready" "done"

# sp### footer Index flip (whole file — footer is usually last line)
sed -i 's/^Index: \[\[board\]\]$/Index: [[archive]]/' "$SP_FILE"

# Physically relocate the delivered spec into the archive mirror.
mkdir -p "$(dirname "$SP_ARCHIVE")"
git -C "$AKM_ROOT" mv "$SP_FILE" "$SP_ARCHIVE"

# Board → archive move. Match `[[sp###` to allow `[[sp012|title]]` aliases.
SP_LINE="$(grep -E "\[\[$SP(\||\])" "$BOARD" || true)"
if [ -n "$SP_LINE" ]; then
  sed -i "/\[\[$SP/d" "$BOARD"
  if grep -q '^## done' "$ARCHIVE"; then
    awk -v line="$SP_LINE" '
      {print}
      /^## done$/ && !done {print ""; print line; done=1}
    ' "$ARCHIVE" > "$ARCHIVE.tmp"
    mv "$ARCHIVE.tmp" "$ARCHIVE"
  else
    printf '\n## done\n\n%s\n' "$SP_LINE" >> "$ARCHIVE"
  fi
else
  echo "WARN: $SP not found in $BOARD — board may have been hand-edited" >&2
fi

# Commit the lifecycle flip as one AKM admin commit on main before closing bd.
# If the commit fails, bd state remains untouched. If bd close fails afterward,
# the ERR trap resets this local commit and restores the file snapshot.
git -C "$AKM_ROOT" add "$SP_ARCHIVE" "$BOARD" "$ARCHIVE"
[ "$HAS_STORY" -eq 0 ] || git -C "$AKM_ROOT" add "$US_FILE" "$IM_FILE"
[ "$HAS_FEATURE" -eq 0 ] || git -C "$AKM_ROOT" add "$FT_FILE"
git -C "$AKM_ROOT" commit -m "feat(akm): archive $SP"

bd close "$EPIC" --reason "Merged via $SP. All child tasks closed by work-audit." >/dev/null

trap - ERR
rm -rf "$BACKUP_DIR"

echo "---"
if [ "$HAS_STORY" -eq 1 ] && [ "$HAS_FEATURE" -eq 1 ]; then
  echo "Archived: $SP → done ($SP_ARCHIVE), $US → done, $IM → accepted, $FT → accepted. Board → archive. Epic $EPIC closed."
elif [ "$HAS_STORY" -eq 1 ]; then
  echo "Archived: $SP → done ($SP_ARCHIVE), $US → done, $IM → accepted. Board → archive. Epic $EPIC closed."
else
  echo "Archived: $SP → done ($SP_ARCHIVE), $FT → accepted. Board → archive. Epic $EPIC closed."
fi
echo "Next: run spec-retro for $SP to refresh AKM graph + push to remote."
