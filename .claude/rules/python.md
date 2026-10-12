---
paths:
  - "**/*.py"
  - "**/pyproject.toml"
  - "**/requirements*.txt"
---

# Python Rules

- Determine the supported Python version from project configuration before using newer syntax.
- Prefer existing project tooling and libraries over adding dependencies.
- Preserve public APIs unless explicitly changing them.
- Use `pathlib` where it improves clarity without violating project conventions.
- Use context managers for files and resources.
- Do not use bare `except:` for normal error handling.
- Avoid mutable default arguments.
- Keep I/O and side effects testable.
- Run the configured formatter/linter/type checker only when the repository uses it; do not introduce a new one incidentally.
