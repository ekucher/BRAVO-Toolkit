# Testing and Validation

After modifications:

1. Run the narrowest relevant check first.
2. Run the project's existing tests for the affected area.
3. Run lint, type checking, syntax checking, or build steps when configured.
4. Inspect the final diff.
5. Confirm no temporary diagnostics remain.

For bug fixes, prefer a regression test that demonstrates the failure before the fix and success after it.

Do not:
- modify tests merely to make incorrect behavior pass;
- delete failing tests without justification;
- claim tests passed when they were not executed;
- ignore failing checks unrelated to the change without reporting them.

If the repository lacks tests, perform the strongest practical deterministic validation and state the limitation.

## BRAVO runtime regression evidence

For a runtime bug fix, where practical: reproduce the defect before the fix,
show the same regression passing after the fix, run affected domain tests, then
run the full self-test when the change can affect production runtime behavior.

Use risk-appropriate cases:

- collection logic: 0 / 1 / N results;
- configuration: current / legacy missing property / invalid value;
- persisted state: clean / legacy / interrupted or partial / retry;
- filesystem behavior: spaces and non-ASCII paths where relevant.

CI evidence is not a substitute for real-server acceptance when the changed
behavior depends on Windows services, Task Scheduler, Credential Manager, boot
semantics, WinSCP/SFTP, restore, or destructive reconciliation. Report that
acceptance requirement explicitly.
