---
paths:
  - "**/*.php"
  - "**/composer.json"
  - "**/composer.lock"
---

# PHP Rules

- Determine the supported PHP version before introducing newer syntax or APIs.
- Preserve encoding behavior in legacy integrations.
- Use strict input validation at HTTP and external-system boundaries.
- Escape output for its destination context.
- Use parameterized database access.
- Do not suppress errors with `@` as a substitute for handling them.
- Preserve public function signatures and API response shapes unless explicitly changing them.
- Avoid unrelated Composer dependency upgrades.
- Run PHP syntax checks on changed PHP files when PHP is available.
