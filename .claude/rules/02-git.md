# Git Rules

- Inspect `git status` before and after significant work.
- Inspect `git diff` before finalizing changes.
- Never commit or push unless explicitly requested. Явне доручення issue/завдання є таким запитом
  для commit і звичайного push власної task-гілки та PR до `developer`; межі — `BRAVO_AGENT_POLICY.md`,
  розділ 13. Push і PR (включно з draft) — лише після локального гейту публікації (розділ 13.12).
- Не додавай closing keywords (`Closes`/`Fixes`/`Resolves #N`) у PR і commit-и без окремого дозволу
  на закриття issue.
- Оновлюй власну гілку з `origin/developer` звичайним merge; rebase опублікованої гілки — лише з
  окремого дозволу (це переписування історії).
- Never stage unrelated files.
- Never use `git reset --hard`, `git clean -fd`, force-push, or destructive history rewriting without explicit instruction.
- Do not amend a commit unless explicitly requested.
- Do not remove another contributor's changes to make the current task easier.
- Commit messages, when requested, must describe one logical change.
- Check staged content for secrets, generated artifacts, logs, dumps, and local configuration before committing.
