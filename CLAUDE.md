# headsup: instructions for Claude sessions working in this repo

## Releases are mandatory (issue #19)

Any push to main that changes behavior (features, fixes, skills, hooks, scripts, setup) MUST go through the release script. Never push release-worthy commits bare.

```bash
scripts/release.sh <major|minor|patch> -m "what changed" [-m "more" ...]
```

The script bumps `VERSION`, prepends a `CHANGELOG.md` section, commits, tags `vX.Y.Z`, and pushes main with tags. It refuses to run on a dirty tree or off main, so land your feature commits first, then cut the release.

Semver convention:

- **PATCH**: bug fixes, doc corrections that affect usage
- **MINOR**: new features, new skills, new hooks
- **MAJOR**: breaking conf or layout changes that require re-running `setup.sh`

Pure typo/comment-only pushes may skip a release, but say so explicitly in the conversation when skipping.

## Bootstrap files

`VERSION` at the repo root is the installed-version source of truth for scripts; `git describe --tags` is the fallback for dev checkouts between releases.
