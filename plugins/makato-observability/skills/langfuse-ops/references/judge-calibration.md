# Judge Calibration Reference

Validate LLM-as-a-Judge outputs against human labels using a Langfuse dataset
experiment. Default to **simple mode** (accuracy only) unless the user asks for
confusion-matrix metrics, thresholds, or production-automation validation.

## Mode Selection

| Condition | Mode |
|-----------|------|
| "does my judge roughly match human labels?" | Simple |
| Confusion matrix, TPR/TNR, thresholds, high-stakes automation | Advanced |
| Ambiguous | Simple |

## Workflow (both modes)

1. Confirm: dataset name, ground-truth label location in `expectedOutput`,
   judge prompt name/version, judge model, label vocabulary.
2. **Fetch current experiment SDK docs before writing any code** — the SDK
   changes frequently; do not rely on memory:
   - https://langfuse.com/docs/evaluation/experiments/experiments-via-sdk
   - https://langfuse.com/docs/evaluation/experiments/datasets
3. Run the judge prompt against each dataset item `input` as a Langfuse
   dataset experiment (creates a dataset run visible in the Experiments UI).
4. Compare judge output to `item.expected_output` inside the evaluator
   function — **never inside the task function**.
5. Return the report format from the section below.

> **NEVER** pass `expectedOutput` into the judge task — that leaks the answer
> and invalidates calibration.

## Label Validation

- Define the allowed label set before computing any metric.
- Normalize only deterministic differences (trim whitespace, uppercase).
- Rows where `expected` or `actual` is outside the allowed set are **invalid**:
  exclude from denominators and report the count.
- Never silently treat unknown labels as negative.

## Simple Mode Metrics

```
exact_match = 1 if actual == expected else 0
accuracy    = sum(exact_match) / valid_rows
```

If `valid_rows == 0`, report accuracy as undefined and ask for valid labels.

## Advanced Mode Metrics (compressed)

Per-row: classify each valid row as TP/FP/FN/TN using the user-defined
positive and negative labels.

Aggregate:
```
accuracy  = (TP + TN) / valid_rows
precision = TP / (TP + FP)          # undefined if TP+FP == 0
recall    = TP / (TP + FN)          # undefined if TP+FN == 0
f1        = 2*precision*recall / (precision+recall)  # 0 if denom == 0
TPR       = TP / (TP + FN)
TNR       = TN / (TN + FP)         # undefined if TN+FP == 0
```

Target for high-stakes automation: TPR > 0.90 and TNR > 0.90.

## Score Names to Emit

Simple: `judge-exact-match`, `judge-accuracy`

Advanced: `judge-exact-match`, `judge-is-tp`, `judge-is-fp`,
`judge-is-fn`, `judge-is-tn`

## Report Format

**Simple:** dataset name + run URL, valid/total rows, invalid-label count,
accuracy, one-sentence recommendation.

**Advanced:** add confusion matrix (TP/FP/FN/TN), all metrics above,
denominator notes for undefined values, top failure direction,
recommendation (ship / iterate / collect more labels / do not automate).

## Common Failure Modes

- Passing `expectedOutput` into the judge task (leaks the answer)
- Using a local SDK dataset when the user expects a Langfuse dataset run in the UI
- Reporting only accuracy when classes are imbalanced
- Missing zero-denominator guards on precision/recall/F1
- Making final quality claims without a held-out split

## After Calibration

- Metrics pass → freeze baseline, monitor drift over time.
- Metrics weak → iterate prompt/few-shots on dev data only, re-calibrate.
- For qualitative diagnosis of disagreements, load `error-analysis.md`.
