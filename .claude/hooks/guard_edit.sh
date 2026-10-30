#!/bin/bash
# PreToolUse on file edits. Refuses secrets and generated files, and asks before
# a change to the gates or the encryption code, so neither weakens unnoticed.
input=$(cat)
file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$input")
root=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}
rel=${file#"$root"/}

decide() {
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}

case "$rel" in
  *key.properties|*.jks|*.keystore|.env|.env.*|*/.env|*.medarchive)
    decide deny "Keystores, key.properties, .env files and record exports stay out of the session.";;
  pubspec.lock|*/pubspec.lock|*/Podfile.lock|*/GeneratedPluginRegistrant.*|build/*|.dart_tool/*)
    decide deny "$rel is generated. Change the source and run flutter pub get or a build.";;
esac

patterns=$root/tool/secret_patterns.txt
if [ -f "$patterns" ] && jq -r '[.tool_input.content, .tool_input.new_string, .tool_input.new_source] | map(select(.)) | join("\n")' <<<"$input" | grep -qE -f "$patterns"; then
  decide deny "That text looks like a real API key or private key. Use a made-up value."
fi

case "$rel" in
  .claude/settings*.json|.claude/hooks/*|.githooks/*|tool/check.sh|tool/repo_guards.sh|tool/test_harness.sh|tool/secret_patterns.txt|.github/workflows/*)
    decide ask "$rel is part of the quality gates.";;
  lib/security/*)
    decide ask "$rel handles encryption keys, so a person should see this change.";;
esac
exit 0
