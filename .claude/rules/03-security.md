# Security Rules

Consider security impact for every externally reachable or privileged code path.

Check as applicable:
- injection;
- path traversal;
- command execution;
- unsafe deserialization;
- authentication and authorization bypass;
- SSRF;
- XSS and CSRF;
- unsafe file upload;
- secrets exposure;
- insecure temporary files;
- race conditions around permissions;
- insecure defaults.

Requirements:
- validate untrusted input at trust boundaries;
- parameterize database queries;
- avoid building shell commands from untrusted strings;
- use least privilege;
- do not log credentials or tokens;
- do not disable certificate validation as a workaround;
- preserve existing access-control checks unless the task explicitly changes policy.

Security-sensitive behavior must fail safely and provide useful diagnostics without leaking secrets.

## BRAVO-specific security boundaries

- BRAVO SFTP connections require explicit SSH host-key verification/pinning; do
  not add accept-any-host-key or interactive-trust fallbacks.
- Password-based SFTP authentication is currently a supported deployment model;
  do not replace it incidentally with key authentication.
- Do not log credential values or secret-bearing connection URIs. Credential
  target identifiers may be logged when operationally useful.
- Runtime/tool integrity verification must not be disabled or downgraded merely
  to make a deployment or test pass. Investigate the unexpected change first.
- Destructive runtime behavior must fail closed when ownership, scope, path,
  remote identity, or integrity cannot be established.
