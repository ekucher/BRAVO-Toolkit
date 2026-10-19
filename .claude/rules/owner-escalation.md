# Owner escalation policy

Claude Code should work autonomously whenever the decision can be made safely
from the repository, tests, documentation, existing architecture, or already
recorded project policy.

Do not stop for routine implementation questions.

## Continue autonomously

Continue working without owner intervention when:

- a failing test can be investigated and fixed;
- CI fails because of implementation, formatting, manifest, lint, or tests;
- an implementation detail can be derived from existing code or tests;
- documentation already defines the intended behavior;
- a regression can be fixed without changing product policy;
- refactoring is needed inside the scope of the delegated task;
- dependencies between repository components can be resolved from the code;
- a branch needs updating from developer (ordinary merge of `origin/developer`;
  rebase of a published branch needs owner permission — `BRAVO_AGENT_POLICY.md`, розділ 13.2);
- additional regression tests are necessary;
- a PR requires changes to become green.

Claude should investigate and resolve these cases itself.

Межі того, що агент робить автономно, а що потребує дозволу власника, визначає
`BRAVO_AGENT_POLICY.md`, розділ 13; цей файл задає лише формат ескалації.

## Escalate to owner

Stop and request owner intervention only when continuing requires one or more
of the following:

1. A product-policy decision that is not already defined.
2. Choosing between incompatible externally visible behaviors when the
   repository does not define the intended behavior.
3. A destructive or irreversible production action.
4. Access to a production server or another real host that Claude cannot access.
5. GitHub administrative configuration outside normal repository changes,
   such as:
   - branch protection;
   - required status checks;
   - repository rulesets;
   - tag protection;
   - organization settings.
6. Credentials, secrets, licenses, private infrastructure, or external access
   that are unavailable.
7. Acceptance of a security or safety regression.
8. A mandatory validation that cannot be executed in the current environment
   and cannot be reasonably delegated to CI.
9. A real-host acceptance step that is explicitly required by release policy.
10. A migration or change affecting production data or fleet state that
    requires explicit owner approval.

## Required escalation format

When owner intervention is genuinely required, stop further work that depends
on that decision and end the response with exactly:

[OWNER_ACTION_REQUIRED]

Then provide:

Reason:
<why autonomous work cannot safely continue>

Need:
<exactly what action or decision is required>

Options:
<option A>
<option B>
<only when there is a genuine choice>

Recommended:
<Claude's recommendation, if one can be made safely>

Blocked task:
<Issue / stage / branch / PR>

Evidence:
<relevant files, tests, errors, CI run, or other concrete evidence>

## Important

Do NOT use [OWNER_ACTION_REQUIRED] for:

- ordinary progress reports;
- successful completion;
- recoverable CI failures;
- test failures that can be investigated;
- routine implementation choices;
- questions answerable by inspecting the repository;
- requests for confirmation before normal coding work;
- uncertainty that can be resolved through additional analysis.

When a task is completed and no owner action is required, do not emit the
marker.

The purpose of owner escalation is to allow long-running autonomous work
without requiring the owner to continuously watch Claude Code.
