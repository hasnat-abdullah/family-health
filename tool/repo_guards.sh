#!/bin/bash
# Project rules the analyzer can't see. Reads tracked (and staged) files, needs
# only git and standard shell tools, and takes under a second.
#   tool/repo_guards.sh
cd "$(git rev-parse --show-toplevel)" || exit 2
failed=0
fail() { echo "guard: $1"; failed=1; }

# Nothing leaves the device: one file may talk to the network, the AI client.
egress_allowed=lib/services/ai/ai_client.dart
hits=$(git grep --cached -lE "package:(http|dio|web_socket_channel|url_launcher)/|(^|[^[:alnum:]_])(HttpClient|WebSocket|(Raw)?Socket\.connect)" -- 'lib/*.dart' 'packages/*/lib/*.dart' | grep -vx "$egress_allowed")
[ -z "$hits" ] || fail "only $egress_allowed may use the network, but these do: $hits"
hits=$(git grep --cached -lE "URLSession|HttpURLConnection|OkHttp" -- 'packages/*.swift' 'packages/*.kt' 'ios/Runner/*.swift' 'macos/Runner/*.swift' 'android/app/src/*.kt')
[ -z "$hits" ] || fail "native code may not use the network: $hits"

# The model never sees family data: what builds the request can't reach it.
hits=$(git grep --cached -lE "^import .*(data/|database|models|storage)" -- lib/services/ai/ai_client.dart lib/services/ai/extraction_prompt.dart)
[ -z "$hits" ] || fail "AI request code may not import the data layer: $hits"

# Keys, keystores and exported records are never committed.
hits=$(git ls-files --cached | grep -E '(^|/)(key\.properties|\.env(\..*)?)$|\.(jks|keystore|medarchive|sqlite|db)$')
[ -z "$hits" ] || fail "sensitive file tracked: $hits"
hits=$(git grep --cached -I -lE -f tool/secret_patterns.txt -- ':!tool/secret_patterns.txt')
[ -z "$hits" ] || fail "possible secret in: $hits"

# Every table can sync: a UUID key and updated_at on each record.
tables=$(awk -v quotes="'''" '/CREATE TABLE/ { name = $3; sub(/\(.*/, "", name); body = $0; while (!index(body, quotes) && (getline line) > 0) body = body " " line; print name "\t" body }' lib/data/database.dart)
while IFS=$'\t' read -r name body; do
  [ -n "$name" ] || continue
  case "$body" in *updated_at*) ;; *) fail "table $name has no updated_at";; esac
  case "$body" in *"id TEXT PRIMARY KEY"*) ;; *) fail "table $name has no UUID primary key";; esac
done <<<"$tables"

# Every action is pinned to a commit, as release builds hold signing secrets.
hits=$(grep -nE '^\s*(- )?uses:' .github/workflows/*.yml | grep -vE '@[0-9a-f]{40}( |$)|uses: (docker://|\./)')
[ -z "$hits" ] || fail "action not pinned to a commit: $hits"

# CI and release builds use one Flutter version.
versions=$(grep -h "FLUTTER_VERSION: '" .github/workflows/*.yml | sort -u | wc -l | tr -d ' ')
[ "$versions" = 1 ] || fail "workflows disagree on FLUTTER_VERSION"

# A released version has a changelog entry.
version=$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)
grep -q "^## $version " CHANGELOG.md || fail "CHANGELOG.md has no section for version $version"

# The agent harness is intact.
jq -e . .claude/settings.json >/dev/null 2>&1 || fail ".claude/settings.json is not valid JSON"
for hook in .claude/hooks/*.sh .githooks/* tool/*.sh; do
  [ -x "$hook" ] || fail "not executable: $hook"
done

# Claude Code only finds skills and agents that say who they are, and reviewers stay read-only.
for skill in .claude/skills/*/SKILL.md; do
  name=$(basename "$(dirname "$skill")")
  grep -q "^name: $name$" "$skill" || fail "$skill needs name: $name"
  grep -q '^description: .' "$skill" || fail "$skill needs a description"
done
for agent in .claude/agents/*.md; do
  name=$(basename "$agent" .md)
  grep -q "^name: $name$" "$agent" || fail "$agent needs name: $name"
  grep -q '^description: .' "$agent" || fail "$agent needs a description"
done
for reviewer in .claude/agents/*-reviewer.md; do
  grep -E '^tools:.*\b(Edit|Write)\b' "$reviewer" >/dev/null && fail "$reviewer must stay read-only"
done
# Skills and agents refer to each other by name, so those names must exist.
for ref in $(grep -rhoE '`[a-z]+(-[a-z]+)+`' .claude/skills .claude/agents | tr -d '`' | sort -u); do
  case "$ref" in *-reviewer|test-author) [ -f ".claude/agents/$ref.md" ] || fail "no agent called $ref";; esac
done

exit $failed
