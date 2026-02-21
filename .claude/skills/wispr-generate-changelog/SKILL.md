---
name: wispr-generate-changelog
description: Use when the user asks to generate a changelog, create release notes, summarize commits since a tag, or format git history into a CHANGELOG entry for EnviousWispr.
---

# Generate Changelog from Conventional Commits

## Find the last release tag

```bash
git -C /Users/m4pro_sv/Desktop/EnviousWispr tag --sort=-version:refname | head -5
```

If no tags exist, use the first commit as the base:
```bash
SINCE=$(git -C /Users/m4pro_sv/Desktop/EnviousWispr rev-list --max-parents=0 HEAD)
```

## Extract commits since the last tag

```bash
TAG=v1.0.0   # replace with actual tag
git -C /Users/m4pro_sv/Desktop/EnviousWispr log "$TAG"..HEAD \
  --pretty=format:"%s" \
  --no-merges
```

## Group commits by type

Pipe the log through these filters (run each separately or combine into a script):

```bash
REPO=/Users/m4pro_sv/Desktop/EnviousWispr
LOG=$(git -C "$REPO" log "$TAG"..HEAD --pretty=format:"%s" --no-merges)

echo "### Features"
echo "$LOG" | grep '^feat' | sed 's/^feat(\([^)]*\)): /- **[\1]** /'

echo ""
echo "### Bug Fixes"
echo "$LOG" | grep '^fix' | sed 's/^fix(\([^)]*\)): /- **[\1]** /'

echo ""
echo "### Refactors"
echo "$LOG" | grep '^refactor' | sed 's/^refactor(\([^)]*\)): /- **[\1]** /'

echo ""
echo "### Other"
echo "$LOG" | grep -Ev '^(feat|fix|refactor|docs|chore|test)' | sed 's/^/- /'
```

## Valid scopes for this project

`asr` `audio` `ui` `llm` `pipeline` `settings` `hotkey` `vad` `build`

## Output format

```markdown
## [1.1.0] — 2026-02-17

### Features
- **[asr]** Add Parakeet v3 streaming support
- **[ui]** Add transcript search to history view

### Bug Fixes
- **[vad]** Correct silence timeout not resetting between sessions
- **[hotkey]** Fix push-to-talk not releasing on app foreground

### Refactors
- **[pipeline]** Extract PipelineState transitions into dedicated method
```

## Create a git tag for the new release

```bash
git -C /Users/m4pro_sv/Desktop/EnviousWispr tag -a v1.1.0 -m "Release v1.1.0"
```

## Notes

- Commits not following conventional format appear under "Other".
- `docs:` and `chore:` commits are typically omitted from user-facing changelogs.
- Check `CHANGELOG.md` in the repo root (if it exists) to prepend the new entry rather than overwriting.
