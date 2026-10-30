#!/bin/bash
# Native README screenshots of the demo family, saved to docs/screenshots/.
#   tool/screenshots.sh <flutter-device-id> <label>
# Device ids: "macos", an iOS simulator UDID, or an Android emulator serial.
# Labels are the file prefix, for example: macos, iphone, ipad, android.
# macOS needs Screen Recording permission for the terminal.
device=$1; label=$2
out=docs/screenshots; mkdir -p "$out"
ADB=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
kind() { case "$1" in macos) echo mac;; emulator-*) echo android;; *) echo ios;; esac; }

case $(kind "$device") in
  ios) xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3;;
  android)
    "$ADB" -s "$device" shell settings put global sysui_demo_allowed 1
    demo() { "$ADB" -s "$device" shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }
    demo enter
    demo clock -e hhmm 0941
    demo battery -e level 100 -e plugged false
    demo notifications -e visible false
    ;;
esac

capture() { # name
  local file="$out/${label}_$1.png"
  case $(kind "$device") in
    mac)
      local id
      id=$(swift tool/window_id.swift "Family Health")
      screencapture -x -o -l"$id" "$file";;
    ios) xcrun simctl io "$device" screenshot "$file" >/dev/null 2>&1;;
    android) "$ADB" -s "$device" exec-out screencap -p > "$file";;
  esac
  echo "saved $file"
}

status=1
while IFS= read -r line; do
  case "$line" in
    *"All tests passed"*) status=0;;
    *"SHOT "*) capture "${line##*SHOT }";;
    *EXCEPTION*|*"Some tests failed"*|*"Timed out"*|*"Expected:"*|*"Actual:"*|*"The finder"*) echo "$line";;
  esac
done < <(flutter test integration_test/screenshots_test.dart -d "$device" 2>&1)

[ "$(kind "$device")" = android ] && demo exit
[ "$(kind "$device")" = ios ] && xcrun simctl status_bar "$device" clear
exit $status
