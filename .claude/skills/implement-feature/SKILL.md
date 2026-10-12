---
name: implement-feature
description: Implement a requested feature in an existing codebase with minimal scope, compatibility analysis, tests, and validation. Use when adding behavior, endpoints, configuration, integrations, or user-visible functionality.
---

# Implement Feature

Implement `$ARGUMENTS`.

1. Locate the current architecture and closest existing pattern.
2. Identify callers, consumers, configuration, persistence, and external contracts affected.
3. Define the smallest design that satisfies the request.
4. Preserve backward compatibility unless breaking behavior is explicitly required.
5. Implement using existing project conventions.
6. Add or update tests for the new behavior.
7. Update configuration/docs only where the feature changes them.
8. Run relevant tests, lint/type/build checks, and inspect the diff.
9. Report implementation choices and any compatibility or migration implications.

Avoid speculative framework changes, broad refactors, and unnecessary dependencies.
