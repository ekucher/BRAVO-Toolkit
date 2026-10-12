---
name: incident-analysis
description: Investigate a production or infrastructure incident, create an evidence-based timeline, identify contributing factors, assess impact, and define corrective actions. Use for outages, crashes, service degradation, restart loops, networking incidents, and postmortem-style analysis.
---

# Incident Analysis

Analyze `$ARGUMENTS`.

Produce:
1. incident scope and observed impact;
2. timestamped event timeline;
3. first known symptom;
4. primary failure;
5. contributing factors;
6. recovery mechanism and whether it was effective;
7. evidence supporting each conclusion;
8. unresolved questions;
9. immediate corrective actions;
10. longer-term prevention and monitoring improvements.

Do not label correlation as causation without supporting evidence.
Prefer commands/checks that can falsify the current hypothesis.
