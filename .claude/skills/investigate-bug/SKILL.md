---
name: investigate-bug
description: Investigate a defect or unexpected behavior, establish evidence, identify the root cause, and propose or implement the narrowest reliable fix. Use for crashes, exceptions, wrong results, regressions, intermittent failures, and unexplained behavior.
---

# Investigate Bug

Investigate `$ARGUMENTS`.

1. Establish expected vs actual behavior.
2. Inspect relevant code, configuration, tests, and recent changes.
3. Reproduce the failure when practical, or derive a concrete failure path from evidence.
4. Trace the execution path from trigger to failure.
5. Separate symptoms from root cause.
6. Check whether the same defect pattern exists elsewhere.
7. Implement the smallest reliable fix if implementation was requested.
8. Add or update a regression test when practical.
9. Run relevant validation.
10. Report:
   - root cause;
   - evidence;
   - files changed;
   - validation performed;
   - remaining uncertainty or risk.

Do not hide the problem with retries, sleeps, exception suppression, or unrelated refactoring.
