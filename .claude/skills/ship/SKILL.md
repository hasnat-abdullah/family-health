---
name: ship
description: Take finished work from the working tree to an open pull request, with the gate and a privacy review. Use when the user asks to ship, or to open a pull request for their changes.
---

# Ship

1. Run `git status` and `git diff`. Stage only what belongs to this change, by path. If unrelated work is in the tree, leave it unstaged and say so.
2. If on `main`, create a branch named for the change, like `fix/ferritin-unit`. If behind `origin/main`, integrate it first.
3. Run `tool/check.sh`. Fix failures. Never skip a hook.
4. Use the `review-change` skill, and resolve anything marked **block**.
5. If the change is user-visible, update `CHANGELOG.md` under an `## Unreleased` section above the latest version, and update `README.md` if it describes the old behaviour.
6. Commit with one imperative sentence, ending with the attribution trailer you've been given, if any.
7. Push the branch and open the pull request with `gh pr create`, filling in `.github/pull_request_template.md`. Tick only boxes that are true, and name the platforms you actually ran it on.
8. Run `gh pr checks --watch` and report the result. If CI fails, fix it and push again.

Don't merge. That's for a person.
