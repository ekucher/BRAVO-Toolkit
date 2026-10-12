---
name: analyze-logs
description: Analyze application, service, web-server, Windows, Linux, or infrastructure logs to build a timeline, correlate symptoms, identify likely root causes, and propose verification steps. Use when the task includes log files or pasted log output.
---

# Analyze Logs

Analyze `$ARGUMENTS`.

1. Determine log source, timezone, process/service, and time window when available.
2. Build a chronological failure timeline.
3. Group repeated messages so frequency does not masquerade as multiple root causes.
4. Correlate:
   - timestamps;
   - process/thread IDs;
   - request IDs;
   - IPs/endpoints;
   - service restarts;
   - upstream/downstream failures.
5. Distinguish:
   - primary failure;
   - secondary/cascade errors;
   - recovery behavior;
   - unrelated noise.
6. Search source/configuration when available to explain messages rather than guessing.
7. Report likely root cause with confidence and evidence.
8. Provide targeted commands or checks that would confirm or reject the hypothesis.

For large files, filter/search first instead of repeatedly reading the entire file.
