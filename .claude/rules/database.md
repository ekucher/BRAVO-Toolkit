---
paths:
  - "**/*.sql"
  - "**/migrations/**"
  - "**/migration/**"
  - "**/schema/**"
---

# Database Rules

- Never run destructive production data operations automatically.
- Do not use `DROP`, `TRUNCATE`, mass `DELETE`, or irreversible migrations without explicit intent and impact analysis.
- Use transactions for multi-step writes when supported and semantically correct.
- Parameterize queries; never concatenate untrusted input into SQL.
- Preserve backward compatibility during rolling deployments when practical.
- Consider indexes and query plans for new high-volume queries.
- Avoid N+1 queries.
- Migration scripts should be deterministic and safe to rerun only when the migration framework expects that behavior.
- Separate schema migration from destructive data cleanup when possible.
- For data migrations, define validation and rollback/recovery strategy before execution.
