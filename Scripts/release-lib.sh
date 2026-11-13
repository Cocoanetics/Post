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

# Current tip of a branch (commit OID).
branch_head() { # repo branch
    gh api "repos/$1/branches/$2" --jq .commit.sha
}

# The text of a file at a ref (branch name or commit OID).
fetch_file() { # repo ref path
    gh api "repos/$1/contents/$3?ref=$2" --jq .content | base64 -d
}

# One commit on `branch` that replaces each local file at its repo path.
# `expected_head` must be the OID the local files were based on, so a
# concurrent push makes the mutation fail instead of silently overwriting it.
# Prints the new commit OID on success. Returns 2 when expectedHeadOid no
# longer matches (caller should re-fetch and retry).
# usage: commit_files repo branch expected_head "message" path=localfile […]
commit_files() {
    local repo="$1" branch="$2" head="$3" message="$4"
    shift 4
    local additions="[]" pair
    for pair in "$@"; do
        additions=$(jq --arg path "${pair%%=*}" --arg contents "$(base64 -i "${pair#*=}")" \
            '. + [{path: $path, contents: $contents}]' <<<"$additions")
    done
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[dry run] would commit '$message' to $repo@$branch (head $head): $*"
        return
    fi
    local response oid
    response=$(jq -n --arg repo "$repo" --arg branch "$branch" --arg head "$head" --arg message "$message" \
        --argjson additions "$additions" '{
            query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }",
            variables: { input: {
                branch: { repositoryNameWithOwner: $repo, branchName: $branch },
                expectedHeadOid: $head,
                message: { headline: $message },
                fileChanges: { additions: $additions }
            } }
        }' | gh api graphql --input -)
    if jq -e '.errors' <<<"$response" >/dev/null 2>&1; then
        if jq -e '.errors[] | select(.message | test("expectedHeadOid|Expected the tip"; "i"))' <<<"$response" >/dev/null 2>&1; then
            return 2
        fi
        echo "$response" | jq -r '.errors[].message' >&2
        return 1
    fi
    oid=$(jq -r '.data.createCommitOnBranch.commit.oid' <<<"$response")
    echo "$oid"
}
