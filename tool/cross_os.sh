#!/bin/bash
# Real backup exchange: every OS exports, every other OS imports its files.
#   tool/cross_os.sh <log-dir> name=device-id [name=device-id ...]
# Device ids: "macos", an iOS simulator UDID, or an Android emulator serial.
logs=$1; shift
mkdir -p "$logs/files"; rm -f "$logs"/files/*
ADB=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
PKG_IOS=com.familyhealth.mediArchive
PKG_ANDROID=com.familyhealth.medi_archive

kind() { case "$1" in macos) echo mac;; emulator-*) echo android;; *) echo ios;; esac; }
docs() { # device → documents folder
  case $(kind "$1") in
    mac) echo "$HOME/Library/Containers/$PKG_IOS/Data/Documents";;
    ios) echo "$(xcrun simctl get_app_container "$1" $PKG_IOS data)/Documents";;
    android) echo "app_flutter";;
  esac
}
pull() { # device file dest
  if [ "$(kind "$1")" = android ]; then
    "$ADB" -s "$1" exec-out run-as $PKG_ANDROID cat "app_flutter/$2" > "$3"
  else cp "$(docs "$1")/$2" "$3"; fi
}
push() { # device src name
  if [ "$(kind "$1")" = android ]; then
    "$ADB" -s "$1" shell "run-as $PKG_ANDROID sh -c 'cat > app_flutter/xos_inbox/$3'" < "$2"
  else cp "$2" "$(docs "$1")/xos_inbox/$3"; fi
}
go() {
  if [ "$(kind "$1")" = android ]; then "$ADB" -s "$1" shell "run-as $PKG_ANDROID touch app_flutter/xos_go"
  else touch "$(docs "$1")/xos_go"; fi
}

pids=(); names=(); ids=()
for pair in "$@"; do
  n=${pair%%=*}; d=${pair#*=}; names+=("$n"); ids+=("$d")
  ( flutter test integration_test/cross_os_test.dart -d "$d" --dart-define=OS_NAME="$n" > "$logs/xos_$n.log" 2>&1 ) &
  pid=$!; pids+=("$pid")
  # One build at a time per platform; wait until this device has exported.
  until grep -q "XOS_READY $n" "$logs/xos_$n.log" 2>/dev/null; do
    kill -0 "$pid" 2>/dev/null || { echo "FAILED before export: $n"; tail -20 "$logs/xos_$n.log"; exit 1; }
    sleep 2
  done
  echo "exported: $n"
  pull "$d" "xos_$n.medarchive" "$logs/files/xos_$n.medarchive"
  pull "$d" "xos_$n.csv" "$logs/files/xos_$n.csv"
done

for i in "${!names[@]}"; do
  for f in "$logs"/files/xos_*; do
    b=$(basename "$f")
    case "$b" in xos_${names[$i]}.*) ;; *) push "${ids[$i]}" "$f" "$b";; esac
  done
  go "${ids[$i]}"
done

status=0
for i in "${!names[@]}"; do
  wait "${pids[$i]}"; c=$?
  echo "${names[$i]}: exit $c | $(grep -E 'XOS_IMPORTED' "$logs/xos_${names[$i]}.log" | tail -1) | $(grep -E 'All tests passed|Some tests failed' "$logs/xos_${names[$i]}.log" | tail -1)"
  [ $c -eq 0 ] || status=1
done
ls -la "$logs/files"
exit $status
