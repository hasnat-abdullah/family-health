---
name: release
description: Start a new minor or major version of the app.
argument-hint: <major.minor, like 1.1 or 2.0>
disable-model-invocation: true
---

# Start version $ARGUMENTS

Releases are automatic: every merge to `main` that changes the app publishes a release for Android, macOS and iOS, each with its own tag, like `android-v1.0.3`. The workflow takes `major.minor` from `version:` in `pubspec.yaml` and adds a patch number that goes up by one each time. This skill is only for moving to a new minor or major version. The merge is what publishes: there's no later step to stop at.

1. Confirm `main` is clean and level with `origin/main`, and that CI on its latest commit is green (`gh run list --branch main --limit 3`).
2. Check the signing secrets are set (`gh secret list`). Without them the Android release fails rather than publish a debug-signed build. See `CONTRIBUTING.md`.
3. On a branch, set `version:` in `pubspec.yaml` to `$ARGUMENTS.0`. The patch number and the `+n` build number are replaced by the workflow, so leave `+n` alone.
4. In `CHANGELOG.md`, turn `## Unreleased` into `## $ARGUMENTS.0 - <today>` (add the section if there is none). Describe changes for users, in plain words. Read `git log` since the last tag to be sure nothing is missing.
5. Run `tool/check.sh`, then use the `ship` skill to open the pull request.
6. Tell the user that merging it publishes the release. Merging is theirs to do, unless they tell you to.
7. After the merge, watch the run with `gh run list --workflow=release.yml --limit 1` and `gh run watch`. Check that each of the three releases (`gh release list`) has its file and `SHA256SUMS.txt`, and report the links.

If a run fails, read why, and fix the cause. A failed run can be re-run from the Actions tab. Don't delete or move a tag or release without asking.
