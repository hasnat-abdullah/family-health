#!/bin/bash
# PreToolUse on Bash. Refuses what must never run unattended and asks about what
# is hard to undo or leaves this machine. A tripwire for mistakes, not a security
# boundary: an agent that wanted to could spell a command another way.
input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input" | tr '\n\t' '  ')

decide() {
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}
deny() { decide deny "$1"; }
ask() { decide ask "$1"; }
has() { grep -qE -- "$1" <<<"$cmd"; }

start='(^|[;&|(] *)([A-Za-z_]+=[^ ]* +)*'
git="${start}git( +-[cC] +[^ ]+)* +"
rest='[^;&|]*'

# Secrets and records.
has '(^|[ /"'\''=])(key\.properties|upload-keystore\.jks|[^ ]+\.(jks|keystore)|\.env(\.[a-z]+)?)([ "'\'';|&)]|$)' &&
  deny "Keystores, key.properties and .env files stay out of the session."
has 'security +(find|dump)-[a-z-]*(password|keychain)' && deny "Don't read the system keychain."
has '[^ ]+\.medarchive' && ask "A .medarchive file holds someone's medical records."

# Skipped gates and rewritten history.
has "${git}(commit|push|merge)${rest} --no-verify" && deny "Don't skip the git hooks: fix what they report."
has "${git}commit${rest} -[a-zA-Z]*n[a-zA-Z]*( |$)" && deny "Don't skip the git hooks: fix what they report."
has "${git}config${rest}(--unset[^;&|]*core\.hooksPath|core\.hooksPath +[^ ;&|])" && deny "core.hooksPath belongs to tool/setup.sh."
has "${git}push${rest} (--force|--force-with-lease|-f|\+[^ ]+)( |=|$)" && deny "Force-pushing rewrites shared history."
has "${start}(flutter|dart) +pub +(publish|lish)" && deny "This package is not published to pub.dev."
has '(curl|wget)[^;&|]*\| *(ba|z)?sh' && deny "Don't pipe a download into a shell."

# Hard to undo.
has "${git}reset${rest} --hard" && ask "git reset --hard discards local work."
has "${git}clean${rest} -[a-zA-Z]*f" && ask "git clean deletes untracked files."
has "${git}(checkout|restore)( +--)? +\.( |$)" && ask "This discards every local change."
has "${git}stash +(drop|clear)" && ask "This deletes stashed work."
has "${git}branch${rest} -D" && ask "This deletes an unmerged branch."
if has "${start}rm +[^;&|]*-[a-zA-Z]*r" && ! has "${start}rm +-[a-zA-Z]+ +(\./)?(build|coverage|\.dart_tool)/?( *$|[;&|])"; then
  ask "Recursive delete outside build output."
fi

# Leaves this machine.
branch=${GUARD_BRANCH:-$(git -C "${CLAUDE_PROJECT_DIR:-.}" branch --show-current 2>/dev/null)}
if has "${git}push"; then
  has "${git}push${rest}(:|[ ])(refs/heads/)?main( |$)" && ask "This pushes straight to main; changes normally go through a pull request."
  has "${git}push${rest} (--tags|v[0-9])" && ask "Pushing a v* tag publishes a release."
  { [ "$branch" = main ] && has "${git}push( +(-u +)?origin)?( *$|[;&|])"; } && ask "This pushes straight to main; changes normally go through a pull request."
fi
has "${git}commit" && [ "$branch" = main ] && ask "This commits straight to main; agents normally work on a branch."
has "${start}gh +secret" && ask "This touches repository secrets."
has "${start}gh +release +(create|delete|edit|upload)" && ask "This changes a public release."
has "${start}gh +repo +(delete|edit|rename|archive)" && ask "This changes the repository."
has "${start}gh +pr +merge" && ask "This merges a pull request. If it changes the version, merging publishes a release."
has "${start}gh +workflow +(run|enable|disable)" && ask "This starts or changes a workflow."
has "${start}gh +api${rest}(-X|--method) *(POST|PUT|PATCH|DELETE)" && ask "This writes through the GitHub API."
has "tool/github_setup\.sh" && ask "This changes the repository's settings on GitHub."
has '(curl|wget)[^;&|]*( -F| --form| -T| --upload-file| -d| --data[a-z-]*| --post-[a-z]+)( |=)' && ask "This uploads data from this machine."
has "${start}(scp|rsync|sftp) +" && ask "This copies files to or from another machine."

# The harness itself.
protected='\.claude/(settings[a-z.]*\.json|hooks/)|\.githooks/|tool/(check|repo_guards|test_harness)\.sh'
has "(>|sed +-i|${start}(rm|mv|cp|chmod|tee) )[^;&|]*(${protected})" && ask "This changes a quality gate."

exit 0
