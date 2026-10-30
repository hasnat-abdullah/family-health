#!/bin/bash
# Stop. A session can't finish on a failing tree: when code changed, this runs the
# gate and hands any failure back to Claude. A tree that passed isn't checked
# again, and one that keeps failing the same way is reported rather than looped on.
input=$(cat)
[ -n "$CI" ] && exit 0
command -v flutter >/dev/null || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

paths=(lib test integration_test packages tool .claude .githooks .github pubspec.yaml analysis_options.yaml CHANGELOG.md)
fingerprint=$({
  git diff HEAD -- "${paths[@]}"
  git ls-files --others --exclude-standard -z -- "${paths[@]}" | xargs -0 shasum 2>/dev/null
} | shasum | cut -d' ' -f1)
empty=$(printf '' | shasum | cut -d' ' -f1)
[ "$fingerprint" = "$empty" ] && exit 0

state=.dart_tool/check; mkdir -p "$state"
[ "$fingerprint" = "$(cat "$state/passed" 2>/dev/null)" ] && exit 0

if output=$(tool/check.sh 2>&1); then
  echo "$fingerprint" >"$state/passed"
  exit 0
fi

if [ "$(jq -r '.stop_hook_active // false' <<<"$input")" = true ] && [ "$fingerprint" = "$(cat "$state/failed" 2>/dev/null)" ]; then
  jq -n --arg m "tool/check.sh still fails on this tree." '{systemMessage: $m}'
  exit 0
fi
echo "$fingerprint" >"$state/failed"
jq -n --arg r "tool/check.sh failed. Fix this, or tell the user why it can't be fixed here:
$(tail -60 <<<"$output")" '{decision: "block", reason: $r}'
