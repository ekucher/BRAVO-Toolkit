---
paths:
  - "**/*.yml"
  - "**/*.yaml"
  - "**/*.json"
  - "**/*.toml"
  - "**/*.ini"
  - "**/*.conf"
---

# Configuration Rules

- Preserve comments and ordering when they carry operational meaning.
- Do not normalize or reformat unrelated configuration.
- Validate syntax with the native tool when available.
- Do not hard-code secrets.
- Preserve existing defaults unless the change explicitly requires new defaults.
- When adding configuration, document allowed values and failure behavior where the project documents configuration.
- Be careful with YAML scalar typing, indentation, quoting, anchors, and duplicate keys.
- Treat production configuration changes as behavior changes and validate their operational impact.

## BRAVO.config compatibility

- Treat repository `BRAVO.config` as the newest schema, not proof that deployed
  site configurations contain every current property.
- New optional properties require a safe canonical default/normalization before
  runtime consumers access them.
- Prefer one compatibility normalization in the canonical configuration loader
  over repeated missing-property checks in consumers.
- Add regression coverage using a legacy configuration that omits each newly
  introduced optional property when runtime code depends on it.
- Validate current, legacy-missing-property, and invalid-value cases under the
  supported Windows PowerShell/StrictMode baseline.
