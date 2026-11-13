#!/bin/bash
# Points the Homebrew formula (cocoanetics/tap/post) at the release tag's
# source tarball. Safe to re-run: a formula already on this version is left alone.

source "$(dirname "$0")/release-lib.sh"

TAP="Cocoanetics/homebrew-tap"
FORMULA="Formula/post.rb"
URL="https://github.com/Cocoanetics/Post/archive/refs/tags/$TAG.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch_file "$TAP" main "$FORMULA" >"$work/post.rb"
if grep -qF "url \"$URL\"" "$work/post.rb"; then
    echo "$FORMULA already points at $TAG"
    exit 0
fi

curl -fsSL --retry 5 --retry-delay 5 -o "$work/source.tar.gz" "$URL"
SHA=$(shasum -a 256 "$work/source.tar.gz" | cut -d' ' -f1)

sed -E -i '' \
    -e "s|^(  url )\".*\"$|\1\"$URL\"|" \
    -e "s|^(  sha256 )\"[0-9a-f]{64}\"$|\1\"$SHA\"|" \
    "$work/post.rb"
grep -qF "url \"$URL\"" "$work/post.rb" && grep -qF "sha256 \"$SHA\"" "$work/post.rb" || {
    echo "Could not update the url/sha256 lines in $FORMULA" >&2
    exit 1
}

diff -u <(fetch_file "$TAP" main "$FORMULA") "$work/post.rb" || true
commit_files "$TAP" main "post $VERSION" "$FORMULA=$work/post.rb"
[[ "$DRY_RUN" == 1 ]] || echo "Updated $FORMULA to $TAG ($SHA)"
