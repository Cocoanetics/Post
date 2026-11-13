#!/bin/bash
# Points the Homebrew formula (cocoanetics/tap/post) at the release tag's
# source tarball. Safe to re-run: a formula already on this version is left alone.

source "$(dirname "$0")/release-lib.sh"

TAP="Cocoanetics/homebrew-tap"
FORMULA="Formula/post.rb"
URL="https://github.com/Cocoanetics/Post/archive/refs/tags/$TAG.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Capture the branch tip before reading the formula, and pass that same OID as
# expectedHeadOid. If the tap advances meanwhile, the mutation fails and we
# retry from a fresh snapshot instead of silently overwriting the intervening edit.
attempts=0
while true; do
    attempts=$((attempts + 1))
    head=$(branch_head "$TAP" main)
    fetch_file "$TAP" "$head" "$FORMULA" >"$work/post.rb"
    if grep -qF "url \"$URL\"" "$work/post.rb"; then
        echo "$FORMULA already points at $TAG"
        exit 0
    fi

    if [[ ! -f "$work/source.tar.gz" ]]; then
        curl -fsSL --retry 5 --retry-delay 5 -o "$work/source.tar.gz" "$URL"
    fi
    SHA=$(shasum -a 256 "$work/source.tar.gz" | cut -d' ' -f1)

    sed -E -i '' \
        -e "s|^(  url )\".*\"$|\1\"$URL\"|" \
        -e "s|^(  sha256 )\"[0-9a-f]{64}\"$|\1\"$SHA\"|" \
        "$work/post.rb"
    grep -qF "url \"$URL\"" "$work/post.rb" && grep -qF "sha256 \"$SHA\"" "$work/post.rb" || {
        echo "Could not update the url/sha256 lines in $FORMULA" >&2
        exit 1
    }

    diff -u <(fetch_file "$TAP" "$head" "$FORMULA") "$work/post.rb" || true
    if [[ "$DRY_RUN" == 1 ]]; then
        commit_files "$TAP" main "$head" "post $VERSION" "$FORMULA=$work/post.rb"
        exit 0
    fi

    set +e
    commit_oid=$(commit_files "$TAP" main "$head" "post $VERSION" "$FORMULA=$work/post.rb")
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        echo "Updated $FORMULA to $TAG ($SHA) at $commit_oid"
        exit 0
    fi
    if [[ $status -eq 2 && $attempts -lt 3 ]]; then
        echo "Tap main moved under us; retrying from a fresh snapshot…" >&2
        continue
    fi
    exit "$status"
done
