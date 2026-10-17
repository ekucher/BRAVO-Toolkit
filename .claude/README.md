# Claude Code project profile

This directory contains project-level Claude Code instructions, scoped rules, and reusable skills.

## Layout

- `CLAUDE.md` — concise project-wide operating contract.
- `rules/` — always-on or path-scoped rules.
- `skills/` — task-specific workflows loaded on demand.
- `agents/` — role definitions from `ai-routing.json`: `lead` (the orchestrator; start the session
  with `claude --agent lead`) and the delegated roles `scout`, `worker`, `tester`, `documentation`,
  `reviewer`, `architect`, `security-reviewer`.

## Useful commands

Inside Claude Code:

- `/context` — verify which instruction files are loaded.
- `/memory` — inspect project/user memory files.
- `/skills` — inspect available skills.
- `/doctor` — diagnose configuration and oversized instruction context.

Example skills:

- `/investigate-bug <problem>`
- `/implement-feature <request>`
- `/code-review <scope>`
- `/security-review <scope>`
- `/analyze-logs <files or problem>`
- `/incident-analysis <incident>`
- `/safe-refactor <scope>`
- `/stabilize-and-modularize` (manual stable -> modularization workflow)
- `/write-tests <scope>`
- `/legacy-change <scope>`
- `/check-readiness`
- `/prepare-commit` (manual only)

## Customization

Edit `CLAUDE.md` for repository-wide invariants.

Keep language/runtime-specific guidance in path-scoped files under `rules/` so it is loaded only when matching files are opened.

Add repository-specific skills only for repeatable workflows. Avoid turning every one-off instruction into a skill.

If the repository has exact build/test commands, add them to `CLAUDE.md` or a dedicated scoped rule. Concrete commands are more effective than generic instructions.
