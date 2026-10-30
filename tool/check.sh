#!/bin/bash
# The one quality gate. Git hooks, Claude Code hooks and CI all run this, so they
# can't drift apart. Prints one line per step, and the log of any step that fails.
#   tool/check.sh           guards, harness, format, analyze, tests and coverage
#   tool/check.sh --fast    the same without tests
cd "$(git rev-parse --show-toplevel)" || exit 2

# Share of the lines loaded by unit tests that must be hit. Raise it, don't lower it.
coverage_floor=80

logs=.dart_tool/check; mkdir -p "$logs"
failed=0

step() {
  name=$1; shift
  if "$@" >"$logs/$name.log" 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name"
    tail -40 "$logs/$name.log"
    failed=1
  fi
}

format_check() { dart format --output=none --set-exit-if-changed lib test integration_test packages/report_ocr/lib; }

coverage_check() {
  awk -F: -v floor="$coverage_floor" '
    /^LF:/ { found += $2 } /^LH:/ { hit += $2 }
    END {
      pct = found ? 100 * hit / found : 0
      printf "%.1f%% of %d lines (floor %d%%)\n", pct, found, floor
      exit pct < floor
    }' coverage/lcov.info
}

step guards tool/repo_guards.sh
step harness tool/test_harness.sh
step format format_check
step analyze flutter analyze
if [ "$1" != --fast ]; then
  step test flutter test --coverage
  step coverage coverage_check
fi
exit $failed
