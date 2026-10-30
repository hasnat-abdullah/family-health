# Contributing

Thanks for helping. Bug reports, fixes, new lab test aliases and report formats from other countries are all useful.

## Ground rules

- **Privacy first.** Features stay on the device unless the user opts in. Never send family data in AI prompts.
- **No real patient data**, in code, tests, issues or screenshots. Use the demo family or made-up values.
- **The model transcribes; code interprets.** Keep values deterministic and checked, and keep the user's review before saving.
- Keep a UUID and `updated_at` on every record, so cloud sync stays possible.

## Getting started

Follow [Build from source](README.md#build-from-source), then:

```sh
tool/setup.sh                                  # git hooks and packages, once per clone
flutter run -d macos --dart-define=DEMO=true   # sample family in separate demo storage
tool/check.sh                                  # everything CI checks: add --fast to skip tests
```

Open a pull request against `main`. CI runs `tool/check.sh` and lints the scripts and workflows, then builds Android, macOS and iOS unless only docs changed.

## Quality gates

`tool/check.sh` is the one gate, and everything else runs it, so a pass here means a pass on CI.

| Check | What it does |
|---|---|
| guards | `tool/repo_guards.sh`: the network is used only by the AI client, AI requests can't reach family data, no secrets or keystores, every table has a UUID and `updated_at`, actions are pinned, and each version has a changelog entry |
| harness | `tool/test_harness.sh`: proves the guards and agent hooks still catch what they should |
| format | `dart format`, at 120 columns |
| analyze | `flutter analyze` |
| test, coverage | `flutter test`, with a coverage floor that only goes up |

`tool/setup.sh` turns on two git hooks: `pre-commit` runs the guards and checks staged Dart, and `pre-push` runs the whole gate.

## Working with Claude Code

The repository is set up for [Claude Code](https://claude.com/product/claude-code). `CLAUDE.md` holds the project's rules and `.claude/rules/` adds detail per area.

- **Hooks** format Dart as it's written, and run the gate before a session can finish. They refuse secrets, force-pushes and skipped git hooks, and ask before anything hard to undo, or that publishes or leaves the machine. They also ask before a change to the gates or `lib/security/`. These are tripwires for mistakes, not a security boundary.
- **Skills** for the work itself:

  | Skill | Use it to |
  |---|---|
  | `/run-app` | run the demo family and look at a change |
  | `/review-change` | run the right reviewers for what changed |
  | `/ship` | go from the working tree to a pull request |
  | `/release` | publish a version |
  | `/fix-ci` | find and fix why a run failed |
  | `/triage-issue` | work through a bug report |
  | `/schema-change` | change what the app stores, through migration and backups |
  | `/add-lab-test` | extend the report reader |
  | `/ai-provider` | add a provider or update its models |
  | `/update-deps` | update packages or Flutter, or assess a Dependabot pull request |
  | `/on-device` | run what CI can't |

- **Agents** look at one thing each. The reviewers are read-only: `privacy-reviewer` traces where data goes, `data-safety-reviewer` looks for ways to lose records, and `clinical-accuracy-reviewer` checks values and wording. `test-author` writes tests that try to break a change, and leaves any bug it finds for you.
- **On GitHub**, Claude reviews new pull requests and answers `@claude` from people with write access. Both do nothing until you run `/install-github-app` in Claude Code.

Maintainers: `tool/github_setup.sh` applies branch protection, secret scanning and security alerts. It's safe to run again.

## On-device tests

```sh
tool/test_device.sh <device-id> <label> <log-dir>          # every suite on one device
flutter test integration_test/report_reading_test.dart -d macos   # or a single suite
tool/cross_os.sh <log-dir> mac=macos android=emulator-5554  # backups exchanged between OSes
```

## Screenshots

`tool/screenshots.sh <device-id> <label>` walks the demo family and saves native captures to `docs/screenshots/`. Labels in use are `macos`, `iphone`, `ipad` and `android`. Run it with the app's other windows closed. macOS needs Screen Recording permission for your terminal.

## Making a release

1. Update `version` in `pubspec.yaml` and add a section to `CHANGELOG.md`.
2. Merge or push that to `main`.

When `pubspec.yaml` reaches `main` with a version that has no tag yet, the [Release workflow](.github/workflows/release.yml) runs the analyzer and tests, builds every installable file, and publishes a GitHub Release with checksums, creating the tag itself. Other `pubspec.yaml` changes, like dependency bumps, don't release anything. A failed run can be re-run from the Actions tab.

Versions with a suffix, like `1.1.0-beta.1`, become pre-releases. You can also push a tag by hand: it must match `pubspec.yaml`, though it may add a suffix. To try the build without publishing, run the workflow by hand from the Actions tab; the files appear as artifacts.

## Android signing

Installed apps only accept updates signed by the same key. Releases are signed with the key in these repository secrets, and publishing fails without them:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the keystore file, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_PASSWORD` | key password |
| `ANDROID_KEY_ALIAS` | key alias |

Keep a backup of the keystore: if it's lost, people have to uninstall to get later releases. To sign locally, put a keystore in `android/` and create `android/key.properties` (both are git-ignored):

```properties
storeFile=upload-keystore.jks
storePassword=...
keyPassword=...
keyAlias=upload
```

Without that file, release builds use the debug key.
