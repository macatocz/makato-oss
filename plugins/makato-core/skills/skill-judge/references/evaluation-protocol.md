# Evaluation Protocol

## Before Starting

- **What is the single most expensive mistake an evaluator could make here?** Inflating scores because the output looks polished.
- **Do I know this domain well enough to judge knowledge delta?** If not, weight D4/D5/D7/D8 more heavily.
- **What pattern does this Skill appear to be targeting?** Identify it before scoring.
- **What would an expert in this domain already know?** This sets your baseline for D1.

## Step 1: First Pass — Knowledge Delta Scan

Mark each section as [E] Expert, [A] Activation, [R] Redundant. Good Skill: >70% Expert, <20% Activation, <10% Redundant.

## Step 2: Structure Analysis

Check frontmatter validity, allowed-tools, line count, reference files, pattern, loading triggers.

## Step 3: Score Each Dimension

MANDATORY: Read `references/failure-patterns.md` before scoring. For scores below 12 or unfamiliar domains, read `references/dimensions.md`.

For each dimension: (1) Find evidence, (2) Assign score, (3) Note improvements.

## Step 4: Calculate Total & Grade

Total = D1+D2+D3+D4+D5+D6+D7+D8. Grade A: 108-120, B: 96-107, C: 84-95, D: 72-83, F: <72.

## Step 5: Generate Report

MANDATORY: Load `references/quick-reference.md`. Write report using that template.

## Step 6: Re-evaluation

Compare dimension scores to prior report. Report mixed results explicitly. Stop at ≤2-point delta: "Score is stable."
