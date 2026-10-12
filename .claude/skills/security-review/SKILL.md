---
name: security-review
description: Perform a focused security review of code or configuration, tracing trust boundaries and identifying exploitable weaknesses with evidence and remediation. Use for authentication, authorization, external input, file handling, network services, shell execution, database access, and security-sensitive changes.
context: fork
---

# Security Review

Review `$ARGUMENTS`.

Map:
- entry points;
- trust boundaries;
- privileges;
- sensitive assets;
- external calls;
- filesystem/database/network effects.

Check relevant classes of weakness:
- injection;
- path traversal;
- auth/authz bypass;
- SSRF;
- XSS/CSRF;
- unsafe deserialization;
- secret exposure;
- unsafe file handling;
- command execution;
- insecure defaults;
- race conditions;
- permission mistakes.

For every finding:
- provide the concrete attack/failure path;
- distinguish exploitable evidence from theoretical concern;
- rate impact and confidence;
- recommend the minimum effective remediation.

Do not weaken security controls to preserve broken behavior.
