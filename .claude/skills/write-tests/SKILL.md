---
name: write-tests
description: Add high-value tests for existing or newly changed behavior, emphasizing regression coverage, boundary cases, failure modes, and stable assertions. Use when tests are missing, a bug needs regression coverage, or a feature needs verification.
---

# Write Tests

Add tests for `$ARGUMENTS`.

1. Inspect the existing test framework and conventions.
2. Test observable behavior, not implementation trivia.
3. Cover:
   - normal path;
   - boundary conditions;
   - invalid input;
   - relevant failure behavior;
   - regression case for known bugs.
4. Keep tests deterministic and isolated.
5. Avoid unnecessary mocks when a stable lower-level test is clearer.
6. Do not change production behavior merely to satisfy a weak test.
7. Run the narrowest relevant tests and report results.
