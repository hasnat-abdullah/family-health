#!/bin/bash
# SessionStart. Prepares the checkout and tells Claude where things stand.
[ -n "$CI" ] && exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
command -v flutter >/dev/null && tool/setup.sh 2>&1 | tail -5

branch=$(git branch --show-current)
echo "Branch: ${branch:-detached}. Uncommitted paths: $(git status --porcelain | wc -l | tr -d ' ')."
if counts=$(git rev-list --left-right --count "HEAD...@{upstream}" 2>/dev/null); then
  read -r ahead behind <<<"$counts"
  [ "$behind" -gt 0 ] && echo "$behind commit(s) behind and $ahead ahead of upstream: integrate before pushing."
fi
[ "$branch" = main ] && echo "On main: create a branch before changing code."
exit 0
