#!/bin/bash
# Publishes the agent skill (Skills/post, from the tagged tree) to ClawHub as
# `post` at Post's version, with the release notes as its changelog. Needs a
# signed-in `clawhub` (`clawhub login`). Safe to re-run: a version already on
# ClawHub is left alone.

source "$(dirname "$0")/release-lib.sh"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)/Skills/post"

if clawhub --no-input inspect post --version "$VERSION" --json >/dev/null 2>&1; then
    echo "ClawHub already has post $VERSION"
    exit 0
fi

CHANGELOG="Post $TAG: https://github.com/Cocoanetics/Post/releases/tag/$TAG"
if [[ -s "${MC_RELEASE_NOTES_FILE:-}" ]]; then
    CHANGELOG="$(cat "$MC_RELEASE_NOTES_FILE")"
fi

if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry run] would publish $SKILL_DIR to ClawHub as post $VERSION with changelog:"
    echo "$CHANGELOG"
    exit 0
fi
clawhub --no-input publish "$SKILL_DIR" --slug post --name Post --version "$VERSION" --changelog "$CHANGELOG"
