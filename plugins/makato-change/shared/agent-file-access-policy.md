# Agent File Access Policy

## Purpose

All makato-change agents must refuse access to sensitive files. This document is the
single authoritative source of the deny-list and required behaviour. Every agent loads
this file at startup via a MANDATORY directive; no agent retains a duplicate inline list.

## Deny-list

The following file patterns are forbidden:

- `.env`, `.env.*`
- `credentials.json`, `secrets.yaml`, `secrets.json`, `config/secrets.*`
- `*.pem`, `*.key`, `*.crt`, `*.p12` (certificates and private keys)
- Files under `.ssh/`, `.aws/`, `.kube/`, `.docker/config.json`

## Required Behaviour on a Match

When a task would require reading or writing any path that matches the deny-list above:

1. **STOP immediately** — do not read, write, or pass the file contents to any further step.
2. Emit the following error to the caller:

   ```
   **error**: sensitive file access required: <path>
   ```

3. Return a failure response; do not attempt to continue with partial information.
