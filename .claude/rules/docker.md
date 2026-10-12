---
paths:
  - "**/Dockerfile"
  - "**/Dockerfile.*"
  - "**/docker-compose.yml"
  - "**/docker-compose.yaml"
  - "**/compose.yml"
  - "**/compose.yaml"
  - "**/.dockerignore"
---

# Docker Rules

- Inspect existing volumes, networks, healthchecks, environment variables, and dependencies before changing container behavior.
- Preserve persistent data volumes.
- Never remove Docker volumes automatically.
- Do not bake secrets into images or Compose files.
- Prefer pinned or intentionally bounded image versions for production.
- Avoid unnecessary host port exposure.
- Preserve existing restart and healthcheck semantics unless intentionally changing them.
- Keep build context minimal.
- Use multi-stage builds when they materially reduce runtime image size or attack surface.
- Do not run application processes as root when the existing image supports an appropriate non-root user.
- Before destructive Compose operations, identify whether named or anonymous volumes contain persistent data.
