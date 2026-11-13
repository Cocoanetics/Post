# Release steps

MissionControl's release recipe for Post runs these after it has tagged
`v<version>` and created the GitHub release (the Release… button, or
`mc release run Cocoanetics/Post`). Each runs in a checkout of the tag, with
`MC_RELEASE_VERSION`, `MC_RELEASE_TAG` and `MC_RELEASE_NOTES_FILE` set.

| Script | What it does |
| --- | --- |
| `release-homebrew.sh` | Points `Formula/post.rb` in Cocoanetics/homebrew-tap at the tag's tarball and sha256. |
| `release-skill.sh` | Sets Cocoanetics/post-skill's version to Post's, then tags and releases it as "Post Skill v<version>". |

They need only a signed-in `gh`. Both are safe to re-run. To run one by hand,
or to preview it without writing anything:

```bash
DRY_RUN=1 Scripts/release-homebrew.sh 1.11.0
Scripts/release-skill.sh 1.11.0
```

The recipe (`mc repo set Cocoanetics/Post --release-recipe @recipe.json`):

```json
{
  "version": { "kind": "tag" },
  "production": {
    "tag": "v{version}",
    "steps": [
      { "kind": "command", "run": ["Scripts/release-homebrew.sh"], "title": "Update Homebrew tap" },
      { "kind": "command", "run": ["Scripts/release-skill.sh"], "title": "Release post-skill" }
    ]
  }
}
```
