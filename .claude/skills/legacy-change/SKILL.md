---
name: legacy-change
description: Modify legacy code conservatively while preserving undocumented compatibility, encoding, file formats, runtime constraints, and operational behavior. Use for old Windows services, legacy PHP, older PowerShell, binary/file integrations, and code with weak test coverage.
---

# Legacy Change

Work on `$ARGUMENTS` conservatively.

Assume unusual existing behavior may be intentional until verified otherwise.

Before editing:
- determine runtime/OS/language versions;
- identify callers and external integrations;
- inspect encodings and file formats;
- inspect configuration lookup rules and system paths;
- identify service/user privilege assumptions;
- check whether tests are incomplete or absent.

Prefer:
- small local changes;
- explicit compatibility checks;
- preserving existing interfaces and output formats;
- additional diagnostics over speculative rewrites.

Do not modernize syntax or architecture merely for aesthetics.

When tests are weak, create a concrete manual verification procedure and clearly report what remains unverified.
