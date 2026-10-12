---
paths:
  - "**/*.sh"
  - "**/*.bash"
---

# Shell Script Rules

- Prefer POSIX-compatible syntax unless Bash is explicitly required.
- For Bash scripts, use strict error handling when compatible with intended control flow.
- Quote variable expansions unless word splitting is intentional.
- Avoid parsing `ls`.
- Validate required commands, files, directories, and parameters.
- Check exit status of commands that determine correctness.
- Use temporary files safely and clean them up.
- Do not embed secrets in scripts.
- Make operational scripts idempotent when practical.
- Add dry-run support for destructive or large-scale changes when practical.
- Use meaningful non-zero exit codes on failure.
