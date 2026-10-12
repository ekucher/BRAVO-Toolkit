---
name: check-readiness
description: Perform a final pre-merge or pre-delivery readiness check over current changes: diff scope, tests, build/lint, compatibility, security, documentation, temporary artifacts, and unresolved risks.
---

# Check Readiness

Check `$ARGUMENTS`.

Verify:
- requested behavior is implemented;
- diff contains no unrelated changes;
- relevant tests pass;
- syntax/build/lint/type checks pass where configured;
- no secrets or temporary debug artifacts are present;
- compatibility implications are understood;
- migrations/configuration changes are documented where necessary;
- failure and rollback considerations are acceptable.

Return a short checklist with PASS / FAIL / NOT VERIFIED and evidence for each material item.

Do not mark PASS without evidence.
