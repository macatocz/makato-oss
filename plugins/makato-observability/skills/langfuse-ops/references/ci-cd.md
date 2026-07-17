# CI/CD Reference

Reference action: [langfuse/experiment-action](https://github.com/langfuse/experiment-action)
Full guide: https://langfuse.com/docs/evaluation/experiments/experiments-ci-cd

## Setup Checklist

- [ ] Confirm the local repository is a GitHub repo. If not, `langfuse/experiment-action`
      does not apply — follow the guide's
      [other CI/CD systems](https://langfuse.com/docs/evaluation/experiments/experiments-ci-cd#other-cicd-systems)
      section instead.
- [ ] Ask which evaluators and run-evaluators the user wants to set up.
- [ ] Ask which regression thresholds (if any) should gate the workflow.
- [ ] **Confirm dataset shape via CLI before writing any code:**

  ```bash
  npx langfuse-cli api datasets list
  npx langfuse-cli api dataset-items list --dataset-name <name> --limit 5
  ```

  Inspect `input`, `expected_output`, and metadata fields so the task
  function extracts them correctly.

- [ ] Use `gh` CLI to check and set secrets for the target repository:

  ```bash
  gh secret list --repo <owner>/<repo>
  gh secret set LANGFUSE_PUBLIC_KEY  --repo <owner>/<repo>
  gh secret set LANGFUSE_SECRET_KEY  --repo <owner>/<repo>
  gh secret set LANGFUSE_HOST        --repo <owner>/<repo>
  # Also set any LLM provider keys the evaluator task needs
  ```

- [ ] Ask how the workflow should be triggered (PR, push, schedule,
      `workflow_dispatch`).
- [ ] If the evaluator uses a third-party dependency, add the install step to the
      workflow before the experiment action.
- [ ] Propose that the user verify the check by actually triggering the workflow
      (e.g. open a test PR).

## Common Issues

| Issue | Fix |
|-------|-----|
| `gh` missing or unauthenticated | `gh auth status` → `gh auth login` before using `gh secret` |
| Local env vars not set | Set `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_HOST` locally before running `langfuse-cli`; never ask the user to paste secret values into chat |
| Wrong action inputs | Confirm `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `langfuse_base_url` (= `LANGFUSE_HOST` value), and provider keys are present in the repo/environment and passed to the action step |
| Forked PR cannot access secrets | GitHub blocks secret access on forked PRs. Document the limitation and use a trusted trigger (internal PR, trusted-branch `push`, or `workflow_dispatch`) |
| No default branch yet | Create an initial empty commit on the intended default branch before trying a PR-triggered workflow |
| Script fails reading dataset fields | Re-inspect dataset items with the CLI; extract fields from object-shaped `input`/`expected_output` explicitly |
