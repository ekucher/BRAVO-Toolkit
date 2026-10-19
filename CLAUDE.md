# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Precedence

This repository already carries two authoritative instruction sets — read them, don't duplicate them:

- `.claude/CLAUDE.md` — project-specific mandatory policy (Ukrainian): startup/handoff protocol via `.claude/PROJECT_STATE.md`, architecture rules, release lifecycle, git authorization gates. This is loaded automatically for Claude Code sessions and takes precedence over anything below.
- `AGENTS.md` (root) — the same engineering discipline in English, with a rule-loading map into `.claude/rules/*.md` (`00-workflow`, `01-change-safety`, `02-git`, `03-security`, `04-testing-validation`, `05-architecture`, `06-release-lifecycle`, `07-bravo-runtime-invariants`, `08-documentation-language`, plus language-specific rules).

**Обов'язково:** канонічні правила агентів — `BRAVO_AGENT_POLICY.md`; маршрут читання — на початку `AGENTS.md`. Межі автономної роботи (що робиться без повторного дозволу для дорученого issue/завдання, а що потребує окремого дозволу власника) — `BRAVO_AGENT_POLICY.md`, розділ 13. Цей файл їх не дублює й не змінює.

Read `.claude/PROJECT_STATE.md` at the start of a session — it is the handoff between sessions (canonical branch/HEAD, active issue/PR, completed waves, `NEXT ACTION`). It does not itself authorize commit/push/merge/tag/release — those always require explicit user instruction in the current task; явне доручення завдання авторизує лише дії розділу 13.1 `BRAVO_AGENT_POLICY.md`.

Documentation in this repo (README, CHANGELOG, docs/, operator runbooks, architecture notes) is written in Ukrainian; keep additions consistent with `.claude/rules/08-documentation-language.md`.

## What this project is

BRAVO-Toolkit is a Windows PowerShell 5.1 toolset that runs backup/archive, health-check, maintenance, data-restore, credential-setup, notification, and Task Scheduler operations for BRAVO/LIMS deployments. It is not a general application — it is operational infrastructure that runs unattended on production Windows hosts (via Scheduled Tasks) and manipulates real backups, real Windows services, and real SFTP-hosted remote copies. Treat every change to Archive/DataRestore/Maintenance/Health/BazaSync/Scheduler/Credentials/System behavior as production-safety-sensitive — see `.claude/rules/07-bravo-runtime-invariants.md` before touching those domains.

## Commands

All commands below are PowerShell, run from the repository root (`ARCHIV` in production installs), Windows PowerShell 5.1 compatible.

| Task | Command |
|---|---|
| Full regression test suite | `.\BRAVO_SELF_TEST.ps1` |
| Run a subset of test suites during development | `.\BRAVO_SELF_TEST.ps1 -Suite DiskSpace,ArchiveDiskSpace` |
| Config-loader tests only | `.\BRAVO_CONFIG_TEST.ps1` |
| Validate install/config without mutating anything | `.\BRAVO_SETUP.ps1 -ValidateOnly` |
| Full install / upgrade | `.\BRAVO_SETUP.ps1` |
| Simulate production operations end-to-end (safe) | `.\BRAVO_DRY_RUN.ps1` |
| Run archive manually | `.\BRAVO_ARCHIV.ps1 -NoPause` |
| Run maintenance manually | `.\BRAVO_MAINTENANCE.ps1` |
| Run health-check manually | `.\BRAVO_HEALTH.ps1` |
| Verify a backup actually restores | `.\BRAVO_RESTORE_TEST.ps1` |
| List restorable generations | `.\BRAVO_DATA_RESTORE.ps1 -ListGenerations` |
| Restore data out-of-place | `.\BRAVO_DATA_RESTORE.ps1 -Mode OutOfPlace -TargetPath "D:\RESTORE"` |
| Inspect Scheduled Task registration (no UAC) | `.\BRAVO_TASKS_DIAGNOSE.ps1 -InspectOnly` |
| Test Scheduled Task access as SYSTEM | `.\BRAVO_TASKS_DIAGNOSE.ps1 -TestAccess` |
| Edit site-specific config via GUI | `.\BRAVO_CONFIGURATOR.ps1` |
| Regenerate runtime integrity manifest (only via canonical script) | `.\ci\Update-BRAVORuntimeManifest.ps1` |
| Regenerate tools manifest (only via canonical script) | `.\ci\Update-BRAVOToolsManifest.ps1` |
| Forbidden-pattern / security static checks | `.\ci\Test-BRAVOForbiddenPattern.ps1`, `.\ci\Invoke-BRAVOSecurityAnalysis.ps1` |
| Release-policy / master-merge-policy checks | `.\ci\Test-BRAVOReleasePolicy.ps1`, `.\ci\Test-BRAVOMasterMergePolicy.ps1` |

`BRAVO_SELF_TEST.ps1` is the primary test entrypoint; individual `-Suite` fragments are not self-contained and consume shared fixtures — do not assume a single suite run is equivalent to the full run when validating a runtime-relevant change. There is a project skill, `run-bravo-toolkit`, for safe local smoke-testing (dry-run, self-test, parse/forbidden checks) without touching production operations — prefer it over inventing an ad hoc validation sequence.

CI-only evidence is not sufficient for changes depending on real Windows services, Task Scheduler, Credential Manager, boot behavior, WinSCP/SFTP, or destructive restore/reconcile semantics — real-server acceptance is required and must be stated explicitly as outstanding when it hasn't run (see `docs/*ACCEPTANCE*` and `docs/*RUNBOOK*` for existing acceptance evidence formats, and `ci/acceptance/` for current acceptance scripts).

## Architecture

Layering, root to leaf:

```
thin root *.ps1 entrypoints  →  modules/BRAVO.<Domain>/  →  canonical implementation  →  tests
```

- Root `BRAVO_*.ps1` files (`ls BRAVO_*.ps1`) are orchestration entrypoints only: params, bootstrap, runtime-integrity guard, module imports, orchestration, exit code. Target ≤250 lines; >350 needs architectural justification; never author a new 1000+ line entrypoint.
- `BRAVO_RUNTIME_GUARD.ps1` is the one exception: it is a pre-trust bootstrap library that must remain independently loadable *before* any `Import-Module` of a not-yet-verified module, so the normal "large file → move into a module" remedy does not apply to it. See `.claude/rules/05-architecture.md` for the exact trust-order requirement if you ever touch it.
- Domain logic lives under `modules/BRAVO.<Domain>/` (`ls modules/` for the current set). Each domain is the canonical owner of its policy — search there before adding a helper anywhere else, and never invent a generic `Common`/`Utils`/`Helpers` dumping-ground module.
- Configuration: canonical built-in defaults and deterministic deep-merge logic live in `modules/BRAVO.Configuration/`. Root `BRAVO_CONFIG_LOADER.ps1` owns orchestration and snapshot execution of the optional `BRAVO.config` / `BRAVO.local.config` and imports this module — do not write a second config parser. See `docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md`.
- Exit codes: single source of truth is `modules/BRAVO.ExitCodes/` — do not reinvent exit-code numeric semantics in entrypoints, acceptance tooling, or scheduler diagnostics.
- `RUNTIME_MANIFEST.json` / `TOOLS_MANIFEST.json`-equivalent integrity manifests are generated artifacts — never hand-edit hashes; regenerate only via `ci/Update-BRAVORuntimeManifest.ps1` / `ci/Update-BRAVOToolsManifest.ps1`, and investigate *why* a tracked file changed before regenerating.
- Dependency direction is entrypoint → domain module → lower-level infrastructure, never the reverse, and never cyclic between domain modules.

"Archive" refers specifically to the backup domain/module, not the whole project.

## Release branches

- `developer` = development/prerelease; `master` = stable only.
- An accepted RC (release candidate) is immutable evidence — no refactor/optimize/dedupe/cleanup on it in place; stable promotion must be a metadata-only diff from the accepted RC (see `.claude/rules/06-release-lifecycle.md` for the full gate).
- Git/GitHub state is the source of truth over any recorded plan or handoff note — verify current branch/HEAD/CI before continuing prior work, and never mutate history (commit/push/merge/tag/rebase/reset) without the user's explicit go-ahead in the current task (явне доручення завдання — це go-ahead лише для дій розділу 13.1 `BRAVO_AGENT_POLICY.md`).

## Windows/PowerShell constraints

- Target runtime is Windows PowerShell 5.1 — do not introduce PowerShell 7-only syntax.
- Respect `Set-StrictMode`, check `$LASTEXITCODE` after native process calls, avoid current-directory assumptions, prefer explicit paths.
- New files must use CRLF to match `.gitattributes`; normalize line endings *before* regenerating `RUNTIME_MANIFEST.json`, or CI (not local runs) will fail with a runtime-integrity violation on a file that looks unchanged locally.

## Agent skills

### Issue tracker

Issues live as GitHub issues on `ekucher/BRAVO-Toolkit` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Standard five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`CONTEXT.md` + `docs/adr/` at the repo root, created lazily by `/domain-modeling`). See `docs/agents/domain.md`.
