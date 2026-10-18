---
name: code-review
description: Review code changes for correctness, regressions, security, compatibility, maintainability, and missing tests. Use for diffs, branches, patches, pull-request-style reviews, or when asked whether a change is safe.
context: fork
---

# Code Review

Review `$ARGUMENTS`.

Prioritize findings by impact:
1. correctness and data loss;
2. security;
3. backward compatibility;
4. concurrency and lifecycle problems;
5. operational reliability;
6. missing validation/tests;
7. maintainability.

For each finding provide:
- severity;
- exact file/location;
- failure scenario;
- why it matters;
- concrete recommended fix.

Do not report style preferences as defects unless they cause real risk or violate an explicit project rule.

Also identify:
- tests that should exist but do not;
- risky assumptions;
- behavior changes hidden inside refactoring.

If no material issues are found, say so and state what was reviewed.
