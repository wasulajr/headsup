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

## Authoring skills (SKILL.md frontmatter)

Every skill's `SKILL.md` opens with a YAML frontmatter block (`name`, `description`). Skill loaders (Claude Code, Codex, and the `~/.agents/skills` scanner) parse that YAML and **silently skip any skill whose frontmatter fails to parse**: there is no error, the skill simply never appears in the menu. Debugging this from the symptom ("my skill is missing") is painful because the file is right there on disk, so prevent it at authoring time.

The most common break is an **unquoted colon in the `description`**. In YAML a plain (unquoted) scalar cannot contain `": "` (a colon followed by a space): the parser reads it as the start of a nested mapping and throws `mapping values are not allowed in this context`. This line is invalid, so the skill vanishes:

```yaml
description: Change colors for Codex sessions: idle, working, and waiting.
```

Rule: if a frontmatter value contains a colon, or starts with a character YAML treats specially (`[ { # & * ! | > % @` or a backtick), wrap the whole value in double quotes. Quoting is always safe, so when in doubt, quote it:

```yaml
description: "Change colors for Codex sessions: idle, working, and waiting."
```

Verify a skill parses before committing (prints nothing and exits 0 on success, prints the YAML error on failure):

```bash
ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]).split(/^---\s*$/)[1])' path/to/SKILL.md
```

If you generate `SKILL.md` files programmatically, have the generator quote description values by default. (Fixed in v0.3.0: `headsup-colors` and `headsup-status` shipped with unquoted colons and were invisible in Codex.)
