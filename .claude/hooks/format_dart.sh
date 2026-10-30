#!/bin/bash
# PostToolUse on file edits. Formats Dart as it's written, and a syntax error
# shows up here, straight after the edit that caused it.
file=$(jq -r '.tool_response.filePath // .tool_input.file_path // ""')
case "$file" in *.dart) ;; *) exit 0;; esac
[ -f "$file" ] && command -v dart >/dev/null || exit 0
dart format "$file" 2>&1 >/dev/null | head -20 >&2
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 2
