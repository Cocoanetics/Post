#!/bin/bash
# Shared by the release steps MissionControl runs after tagging a Post release
# (see Scripts/README.md). Everything goes through the GitHub API, so a step
# needs a signed-in `gh` but no clone, SSH key or local git.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

VERSION="${MC_RELEASE_VERSION:-${1:-}}"
VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>   (or set MC_RELEASE_VERSION)" >&2
    exit 64
fi
TAG="${MC_RELEASE_TAG:-v$VERSION}"
DRY_RUN="${DRY_RUN:-0}"

# The text of a file on a repo's branch.
fetch_file() { # repo branch path
    gh api "repos/$1/contents/$3?ref=$2" --jq .content | base64 -d
}

# One commit on `branch` that replaces each local file at its repo path.
# usage: commit_files repo branch "message" path=localfile [path=localfile…]
commit_files() {
    local repo="$1" branch="$2" message="$3"
    shift 3
    local head
    head=$(gh api "repos/$repo/branches/$branch" --jq .commit.sha)
    local additions="[]" pair
    for pair in "$@"; do
        additions=$(jq --arg path "${pair%%=*}" --arg contents "$(base64 -i "${pair#*=}")" \
            '. + [{path: $path, contents: $contents}]' <<<"$additions")
    done
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[dry run] would commit '$message' to $repo@$branch (head $head): $*"
        return
    fi
    jq -n --arg repo "$repo" --arg branch "$branch" --arg head "$head" --arg message "$message" \
        --argjson additions "$additions" '{
            query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { url } } }",
            variables: { input: {
                branch: { repositoryNameWithOwner: $repo, branchName: $branch },
                expectedHeadOid: $head,
                message: { headline: $message },
                fileChanges: { additions: $additions }
            } }
        }' | gh api graphql --input - --jq .data.createCommitOnBranch.commit.url
}
