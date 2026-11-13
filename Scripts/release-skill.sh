#!/bin/bash
# Releases the Post skill (Cocoanetics/post-skill) at the same version as Post:
# sets the version in SKILL.md and metadata.json, then tags and creates the
# GitHub release. Safe to re-run: an existing release is left alone.

source "$(dirname "$0")/release-lib.sh"

SKILL="Cocoanetics/post-skill"

if gh release view "$TAG" -R "$SKILL" >/dev/null 2>&1; then
    echo "$SKILL already has release $TAG"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch_file "$SKILL" main SKILL.md >"$work/SKILL.md"
fetch_file "$SKILL" main metadata.json >"$work/metadata.json"
sed -E -i '' "1,/^---$/s|^version: .*$|version: $VERSION|" "$work/SKILL.md"
sed -E -i '' "s|^(  \"version\": )\"[^\"]*\"|\1\"$VERSION\"|" "$work/metadata.json"
grep -qx "version: $VERSION" "$work/SKILL.md" && grep -qF "\"version\": \"$VERSION\"" "$work/metadata.json" || {
    echo "Could not set the version in SKILL.md / metadata.json" >&2
    exit 1
}

if ! cmp -s <(fetch_file "$SKILL" main metadata.json) "$work/metadata.json" ||
   ! cmp -s <(fetch_file "$SKILL" main SKILL.md) "$work/SKILL.md"; then
    commit_files "$SKILL" main "Bump to $TAG for Post $TAG" \
        "SKILL.md=$work/SKILL.md" "metadata.json=$work/metadata.json"
fi

{
    echo "## Post Skill $TAG"
    echo
    echo "Aligned with [Post $TAG](https://github.com/Cocoanetics/Post/releases/tag/$TAG)."
    if [[ -s "${MC_RELEASE_NOTES_FILE:-}" ]]; then
        echo
        cat "$MC_RELEASE_NOTES_FILE"
    fi
} >"$work/notes.md"

if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry run] would create release $TAG on $SKILL with notes:"
    cat "$work/notes.md"
    exit 0
fi
gh release create "$TAG" -R "$SKILL" --target main --title "Post Skill $TAG" --notes-file "$work/notes.md"
