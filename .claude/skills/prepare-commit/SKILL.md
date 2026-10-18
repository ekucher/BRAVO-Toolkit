---
name: prepare-commit
description: Inspect current changes and prepare a clean, focused Git commit proposal. Invoke manually when you want Claude to review staging scope and formulate a commit; it must not push.
disable-model-invocation: true
---

# Prepare Commit

Prepare a commit for `$ARGUMENTS`.

1. Inspect `git status`.
2. Inspect unstaged and staged diffs.
3. Identify unrelated, generated, temporary, secret, log, dump, or local-environment files.
4. Determine the minimal file set for one logical commit.
5. Run relevant validation if it has not already been run.
6. Propose:
   - files to stage;
   - concise commit subject;
   - optional body when rationale is not obvious.
7. Only create the commit if the user's request explicitly asks to commit.
8. Never push unless separately and explicitly requested.

Do not stage unrelated files.
