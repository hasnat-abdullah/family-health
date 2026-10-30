---
name: run-app
description: Launch the app with the demo family and look at a change working, using hot reload and screenshots. Use when asked to run or try the app, or to check how a UI change looks.
argument-hint: <what to look at>
---

# Run the app

Always use demo mode. It keeps a made-up family in separate storage, so the real records on this machine stay closed and out of the session.

```sh
flutter devices
flutter run -d macos --dart-define=DEMO=true
```

Run it in the background, with a log file in a temporary directory. Prefer macOS unless the change is specific to a platform. The first build takes a few minutes.

If the `dart` MCP server is connected, use its tools: `launch_app` with the same `--dart-define`, then `hot_reload`, `get_runtime_errors`, `get_app_logs` and the widget inspector. Hot reload won't apply changes to `main`, or to code that has already run at startup. Restart for those.

To see it, take a screenshot and read the image. On macOS, `screencapture -x <file>` needs Screen Recording permission for the terminal. If you can't see the screen, say so rather than assume it looks right.

Check the thing you changed, then what's around it: dark mode, a narrow window, large text, and an empty state, and that the log has no new errors.

For measured checks of tap targets, contrast and overflow, run `flutter test integration_test/ui_ux_test.dart -d macos`.

Stop the app when you're done. Don't commit screenshots from here: `tool/screenshots.sh` makes the README's, through the `on-device` skill.
