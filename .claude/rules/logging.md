# Logging and Diagnostics

- Logs must help an operator identify what failed and where.
- Include relevant object, path, service, operation, or correlation context.
- Never log passwords, API tokens, private keys, session secrets, or full credential-bearing URLs.
- Avoid excessive logging in hot loops.
- Preserve the project's existing log levels and format.
- Temporary debug logging must be removed after diagnosis unless it provides lasting operational value.
- When analyzing logs, correlate events by timestamp, process/service, request, and causal sequence rather than treating isolated error lines as root causes.
