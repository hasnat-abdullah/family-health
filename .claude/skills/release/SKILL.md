---
name: release
description: Prepare and publish a new version of the app.
argument-hint: <version, like 1.1.0 or 1.1.0-beta.1>
disable-model-invocation: true
---

# Release $ARGUMENTS

When a new `version:` in `pubspec.yaml` reaches `main`, the Release workflow publishes installable files to everyone and creates the tag itself. So the merge is what publishes: there's no later step to stop at.

1. Confirm `main` is clean and level with `origin/main`, and that CI on its latest commit is green (`gh run list --branch main --limit 3`).
2. Check the signing secrets are set (`gh secret list`). Without them the workflow fails rather than publish a debug-signed Android build. See `CONTRIBUTING.md`.
3. On a branch, set `version:` in `pubspec.yaml`. A suffix like `1.1.0-beta.1` makes a pre-release. The build number comes from the workflow run, so leave `+n` alone.
4. In `CHANGELOG.md`, turn `## Unreleased` into `## <version> - <today>`. Describe changes for users, in plain words. Read `git log` since the last tag to be sure nothing is missing.
5. Run `tool/check.sh`, then use the `ship` skill to open the pull request.
6. Tell the user that merging it publishes the release. Merging is theirs to do, unless they tell you to.
7. After the merge, watch the run with `gh run list --workflow=release.yml --limit 1` and `gh run watch`. Check that the release has every file and `SHA256SUMS.txt`, and report the link.

If a run fails, read why, and fix the cause. A failed run can be re-run from the Actions tab. Don't delete or move a tag or release without asking.
