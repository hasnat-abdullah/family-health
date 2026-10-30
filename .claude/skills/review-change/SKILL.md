---
name: review-change
description: Review the current change with the project's specialist reviewers, chosen by what it touches. Use before opening a pull request, or when asked to review a change for privacy, data safety or medical accuracy.
---

# Review a change

1. Run `git diff --merge-base origin/main --stat`, and include uncommitted work. If there's nothing to review, say so.
2. Choose reviewers from what changed. Run the ones that apply in parallel:

   | If the change touches | Run |
   |---|---|
   | the network, AI reading, logging, file handling, permissions, dependencies, `lib/security/` | `privacy-reviewer` |
   | `lib/data/`, models, backups, CSV, the file store, anything that deletes | `data-safety-reviewer` |
   | `lib/data/lab_catalog.dart`, report parsing, AI checks, charts, flags, medicine schedules, health text | `clinical-accuracy-reviewer` |

   Changes to docs, or the harness alone, need none of them.
3. If new logic in those areas has no tests, run `test-author` on it.
4. Check each finding against the code before you repeat it, since reviewers can be wrong. Drop what doesn't hold up.
5. Fix every **block**, then run `tool/check.sh`. Re-run a reviewer only if the fix changed what it looked at.
6. Report what you ran, what you fixed, and any **note** left for the user to decide. If you skipped a reviewer, say why.
