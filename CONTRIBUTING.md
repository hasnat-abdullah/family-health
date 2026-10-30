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
flutter run -d macos --dart-define=DEMO=true   # sample family in separate demo storage
flutter analyze
flutter test
```

Open a pull request against `main`. CI runs the analyzer and unit tests, then builds Android, macOS and iOS.

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
2. Commit, then tag and push:

   ```sh
   git tag v1.1.0
   git push origin main v1.1.0
   ```

The [Release workflow](.github/workflows/release.yml) refuses a tag that doesn't match `pubspec.yaml`, builds every installable file, and publishes a GitHub Release with checksums. Tags with a suffix, like `v1.1.0-beta.1`, become pre-releases. To try the build without publishing, run the workflow by hand from the Actions tab; the files appear as artifacts.

## Android signing

Installed apps only accept updates signed by the same key. Releases are signed with the key in these repository secrets:

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
