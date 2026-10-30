#!/bin/bash
# Runs every on-device suite on one device, one suite at a time.
#   tool/test_device.sh <flutter-device-id> <label> <log-dir> [suite ...]
device=$1; label=$2; logs=$3; shift 3
suites=("$@"); [ ${#suites[@]} -eq 0 ] && suites=(report_reading data_flow ai_flow device_services e2e_ui ui_ux)
mkdir -p "$logs"
# Android: grant notification permissions as each test install appears.
case "$device" in emulator-*)
  ADB=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
  ( while kill -0 $$ 2>/dev/null; do
      "$ADB" -s "$device" shell pm grant com.familyhealth.medi_archive android.permission.POST_NOTIFICATIONS 2>/dev/null
      "$ADB" -s "$device" shell appops set com.familyhealth.medi_archive SCHEDULE_EXACT_ALARM allow 2>/dev/null
      sleep 1
    done ) &
;; esac
for s in "${suites[@]}"; do
  log="$logs/${label}_$s.log"
  flutter test "integration_test/${s}_test.dart" -d "$device" > "$log" 2>&1
  code=$?
  echo "$label $s: exit $code | $(grep -E 'All tests passed|Some tests failed' "$log" | tail -1) $(grep -E '^UI/UX: ' "$log" | cut -d';' -f1)"
done
