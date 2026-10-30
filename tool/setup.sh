#!/bin/bash
# Prepares a clone or worktree for development. Safe to run again at any time.
#   tool/setup.sh
cd "$(git rev-parse --show-toplevel)" || exit 2

[ "$(git config core.hooksPath)" = .githooks ] || git config core.hooksPath .githooks

if [ ! -f .dart_tool/package_config.json ] || [ pubspec.lock -nt .dart_tool/package_config.json ]; then
  flutter pub get
fi

wanted=$(sed -n "s/.*FLUTTER_VERSION: '\(.*\)'/\1/p" .github/workflows/ci.yml)
actual=$(flutter --version --machine 2>/dev/null | jq -r .frameworkVersion)
[ "$wanted" = "$actual" ] || echo "Flutter is $actual here but CI uses $wanted."

for tool in jq gh; do
  command -v "$tool" >/dev/null || echo "Missing $tool: the hooks need jq, and pull requests need gh."
done
for tool in shellcheck actionlint; do
  command -v "$tool" >/dev/null || echo "Optional: install $tool to run CI's script and workflow lint locally."
done
exit 0
