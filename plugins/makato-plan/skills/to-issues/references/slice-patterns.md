# Slice Patterns Reference

Expert patterns for vertical slice decomposition in the To Issues skill.

## Tracer-Bullet Slice Pattern

A tracer-bullet slice cuts end-to-end from input to observable output, touching every layer
exactly once. The minimum viable tracer bullet for a web feature is:

1. Route/endpoint that accepts the input
2. Handler that calls the domain function
3. Domain function that implements the logic
4. Persistence layer that saves/reads the result
5. Test that drives the happy path from outside

**Anti-pattern**: horizontal slices that implement "the database layer for all features" then
"the API layer for all features." These cannot be tested or deployed independently.

## Context Boundary Detection

### K8s context signals

- File paths: `helm/`, `charts/`, `app.py`, `corelib/`, `k8s-monitor/`
- Code patterns: `BaseTask`, `CronJob`, `TaskOrchestrator`, `MSSQLConnection`
- Language: Python, YAML Helm values, Kubernetes manifests

### AWS Infra context signals

- File paths: `templates/`, `Lambda-*/`, `*.yml` (CloudFormation)
- Code patterns: `lambda_handler`, `MSSQLLambda`, `SOLWLambda`, `cfnresponse`
- Language: Python Lambda, CloudFormation YAML, PowerShell

### Ambiguity resolution

If a slice modifies both a CloudFormation template AND a K8s Python service, split it:

- Slice A: CloudFormation change only (`context:aws-infra`)
- Slice B: K8s service change only (`context:k8s`)

## Autonomous vs Needs Human Decision Tree

```text
Does the slice require ANY of:
  - Architectural decision not yet made?
  - Access to external system without test doubles?
  - Judgment call about product behavior?
  → Needs Human

Does the slice have ALL of:
  - Complete acceptance criteria?
  - Identified files to create/modify?
  - Passing test that defines "done"?
  → Autonomous
```

## Issue Body Quality Checklist

A well-formed issue body must include:

1. **Context** — what system/module is affected and why
2. **What to build** — concrete description of the change
3. **Acceptance criteria** — specific, testable conditions
4. **Files** — exact file paths to create or modify
5. **Slice type** — `Autonomous` or `Needs Human` with reason

Missing any of these forces the Specialist to ask questions mid-session.
