---
name: on-device
description: Run the on-device test suites or regenerate the README screenshots. Use for anything CI can't cover, like OCR, encryption, notifications, backups between OSes and how screens look.
argument-hint: <suite, or "screenshots">
---

# On-device checks

Run `flutter devices` first, and use only devices that are there. Don't start, erase or change an emulator or simulator without asking. These tests install the app, and on a real phone they can touch its data, so ask before using one.

Logs go in a new temporary directory, not the repo.

| To check | Run |
|---|---|
| Every suite on a device | `tool/test_device.sh <device-id> <label> <log-dir>` |
| Named suites | `tool/test_device.sh <device-id> <label> <log-dir> report_reading data_flow` |
| One suite | `flutter test integration_test/report_reading_test.dart -d <device-id>` |
| Backups between OSes | `tool/cross_os.sh <log-dir> mac=macos android=emulator-5554` |
| README screenshots | `tool/screenshots.sh <device-id> <label>` |

Suites: `report_reading`, `data_flow`, `ai_flow`, `device_services`, `e2e_ui`, `ui_ux`.

`tool/test_device.sh` exits non-zero if any suite fails, and prints a line per suite. Read the failing suite's log before saying why it failed.

Screenshot labels are `macos`, `iphone`, `ipad` and `android`. Screenshots must show only the demo family. Look at each new image before you keep it. macOS needs Screen Recording permission for the terminal, and the app's other windows closed.

Report which devices and suites ran and which didn't.
