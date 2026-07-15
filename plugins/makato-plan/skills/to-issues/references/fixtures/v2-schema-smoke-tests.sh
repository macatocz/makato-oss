#!/usr/bin/env bash
# Smoke tests for the to-issues v2.0-schema contract (#228).
#
# to-issues is a prose skill — its logic lives in SKILL.md + label-taxonomy.md
# and is executed by an agent, not a script. This file is the *executable spec*
# for the deterministic core of that logic: it re-implements the field-path,
# module-match (informative-token filter), title, and points/priority derivation
# rules exactly as the prose describes them, runs them against the committed
# v2.0 fixture, and asserts the acceptance criteria from issue #228:
#
#   1. Title is bound from `summary` (non-empty) — not a missing `title` field.
#   2. type/tech/module inference reads summary + description.scope +
#      description.background (v2.0 paths), not a flat title+scope.
#   3. The module match uses a LANGUAGE-NEUTRAL document-frequency filter so a
#      batch-universal connective (`and` in English, `pro` in Czech, …) cannot
#      drive a match against an ADR slug that happens to contain it — with no
#      hard-coded, English-only stopword list.
#   4. The five prioritization dimensions resolve from labels[] / storyPoints,
#      with no `metadata` object present.
#
# If the prose in SKILL.md / label-taxonomy.md changes the algorithm, update
# this reference implementation in lockstep — a drift here means the spec and
# its guard disagree.
#
# Pure bash + python3 stdlib. No gh, no network, no agent.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FIXTURE="$REPO_ROOT/plugins/makato-plan/skills/to-issues/references/fixtures/v2-schema-regression.stories.json"

pass=0
fail=0

# check <test-name> <expected> <actual>
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s → %s\n' "$name" "$actual"
  else
    fail=$((fail + 1))
    printf '  ✗ %s: expected [%s], got [%s]\n' "$name" "$expected" "$actual"
  fi
}

echo "== to-issues v2.0-schema regression (#228) =="

# Reference implementation of the deterministic core, per SKILL.md Step 3 and
# label-taxonomy.md. Emits `key=value` lines the bash harness asserts on.
# If the prose changes the algorithm, update this block in lockstep.
RESULT="$(python3 - "$FIXTURE" <<'PY'
import json
import re
import sys
from collections import Counter

fixture = json.load(open(sys.argv[1]))

# ADR folder slugs — mirrors the sagibeast specs/Architecture layout that
# surfaced the bug. The `and`-bearing slug is the regression anchor.
ADR_SLUGS = [
    "06-brain-body-contract",
    "11-data-privacy-and-confidentiality",
    "some-unrelated-module",
]

SIZE_MAP = {"s": 1, "m": 3, "l": 8, "xl": 13}
SEV_TO_PRIO = {"critical": "p0", "high": "p1", "medium": "p2", "low": "p3"}
TIER_TO_PRIO = {"foundation": "p0", "happy-path": "p1", "edge-cases": "p3"}


def tokenize(text):
    """Lowercase, split on non-alphanumerics, keep tokens >= 3 chars.

    NOTE: no word list — the filter that removes connectives is the
    document-frequency filter below, which is language-neutral.
    """
    return {t for t in re.split(r"[^a-z0-9]+", text.lower()) if len(t) >= 3}


def uninformative_tokens(story_token_sets, config_stopwords=frozenset()):
    """Language-neutral informative-token filter (label-taxonomy.md).

    A token is uninformative — dropped from both story and slug token sets
    before matching — when it appears in more than half the batch AND in at
    least two stories (df > N/2 and df >= 2). Batch-universal connectives in
    ANY language cross this threshold; distinctive domain terms do not.
    With N == 1 the df >= 2 guard is never met, so nothing is frequency-
    filtered (the signal is undefined for a single document).

    `config_stopwords` (optional .claude/config.json labels.module_stopwords)
    is dropped in addition, purely opt-in; default empty.
    """
    n = len(story_token_sets)
    df = Counter()
    for toks in story_token_sets:
        for t in toks:
            df[t] += 1
    freq_drop = {t for t, c in df.items() if c > n / 2 and c >= 2}
    return freq_drop | set(config_stopwords)


def modules_for_batch(inference_texts, config_stopwords=frozenset()):
    """Return, per story index, the sorted list of matched ADR slugs."""
    story_sets = [tokenize(t) for t in inference_texts]
    drop = uninformative_tokens(story_sets, config_stopwords)
    result = []
    for toks in story_sets:
        informative = toks - drop
        matched = [
            slug for slug in ADR_SLUGS if (tokenize(slug) - drop) & informative
        ]
        result.append(sorted(matched))
    return result


def label_value(labels, prefix):
    for lab in labels:
        if lab.startswith(prefix + ":"):
            return lab.split(":", 1)[1]
    return None


stories = fixture["stories"]
inference_texts = [
    " ".join(
        [
            s["summary"],
            s["description"].get("scope", ""),
            s["description"].get("background", ""),
        ]
    )
    for s in stories
]
batch_modules = modules_for_batch(inference_texts)

out = []
for idx, story in enumerate(stories):
    seq = story["sequence"]
    summary = story["summary"]
    labels = story.get("labels", [])

    # (1) title binding — from summary, must be non-empty
    out.append(f"story{seq}.title_nonempty={'yes' if summary.strip() else 'no'}")

    # (2)+(3) module match via informative-token filter (v2.0 field paths)
    matched = batch_modules[idx]
    out.append(f"story{seq}.modules={','.join(matched) or '_none_'}")

    # (4) points resolution (fixture path): labels[] → storyPoints.
    #     Full prose order is labels[] → legacy metadata.points → storyPoints
    #     → effort/SIZE_MAP; the legacy-metadata and effort fallbacks aren't
    #     exercised by this v2.0 fixture, so they're omitted here.
    points = label_value(labels, "points")
    if points is None:
        sp = story.get("storyPoints")
        if isinstance(sp, int) and sp > 0:
            points = str(sp)
    out.append(f"story{seq}.points={points or '_none_'}")

    # severity from labels[], priority derived when absent.
    # Priority resolution order (fixture path): labels[] → severity → tier.
    # `tier` is copied from stories[].phase (see prose bullet 2); severity
    # wins over tier, so tier-derivation only fires when severity is absent.
    severity = label_value(labels, "severity")
    tier = story.get("phase")
    priority = label_value(labels, "priority")
    if priority is None and severity in SEV_TO_PRIO:
        priority = SEV_TO_PRIO[severity]
    elif priority is None and tier in TIER_TO_PRIO:
        priority = TIER_TO_PRIO[tier]
    out.append(f"story{seq}.severity={severity or '_none_'}")
    out.append(f"story{seq}.priority={priority or '_none_'}")

    # confirm no metadata object exists in the v2.0 fixture
    out.append(f"story{seq}.has_metadata={'yes' if 'metadata' in story else 'no'}")

print("\n".join(out))
PY
)"

get() { echo "$RESULT" | grep -F "$1=" | cut -d= -f2-; }

# (1) title bound from summary — non-empty
check "story1 title bound from summary" "yes" "$(get story1.title_nonempty)"

# (3) THE regression: story1 mentions 'brain'/'body' (in description.background —
#     which also proves (2), that background is read) → matches brain-body-contract.
#     It says "and" repeatedly, but "and" is batch-universal → filtered → it must
#     NOT match the and-bearing slug.
check "story1 module match (no 'and' false-positive)" \
  "06-brain-body-contract" "$(get story1.modules)"

# story2 mentions privacy/confidentiality/data → legitimately matches the and-slug
#     on those distinctive tokens, never on the filtered 'and'.
check "story2 module match (matches on privacy, not 'and')" \
  "11-data-privacy-and-confidentiality" "$(get story2.modules)"

# (4) points derived from storyPoints (no metadata block present)
check "story1 points derived from storyPoints" "8" "$(get story1.points)"
check "story2 points derived from storyPoints" "5" "$(get story2.points)"

# severity read from labels[]; priority derived from it
check "story1 severity from labels[]" "high" "$(get story1.severity)"
# story1 has BOTH severity:high AND phase:foundation → severity wins over tier (p1, not p0)
check "story1 priority derived from severity (wins over tier)" "p1" "$(get story1.priority)"
check "story2 severity absent" "_none_" "$(get story2.severity)"
# story2 has NO severity but phase:happy-path → priority derived from tier (v3.7.0+)
check "story2 priority derived from tier (happy-path→p1)" "p1" "$(get story2.priority)"

# v2.0 fixture carries NO metadata object
check "story1 no metadata object" "no" "$(get story1.has_metadata)"
check "story2 no metadata object" "no" "$(get story2.has_metadata)"

echo ""
echo "== module-match informative-token filter — language-neutrality =="

# The filter enumerates NO words. To prove it is not English-specific, run it on
# a Czech batch whose connective is `pro` ("for"), against an ADR slug that
# contains `pro`. `pro` is batch-universal → filtered → no false match, exactly
# as `and` is in English. A hard-coded English stopword list could never do this.
LANG="$(python3 <<'PY'
import re
from collections import Counter

ADR_SLUGS = ["14-nastroje-pro-agenty", "15-fakturace-modul", "12-billing-service"]


def tokenize(text):
    return {t for t in re.split(r"[^a-z0-9]+", text.lower()) if len(t) >= 3}


def uninformative(sets, extra=frozenset()):
    n = len(sets)
    df = Counter()
    for s in sets:
        for t in s:
            df[t] += 1
    return {t for t, c in df.items() if c > n / 2 and c >= 2} | set(extra)


def modules(texts, extra=frozenset()):
    sets = [tokenize(t) for t in texts]
    drop = uninformative(sets, extra)
    return [
        sorted(s for s in ADR_SLUGS if (tokenize(s) - drop) & (toks - drop))
        for toks in sets
    ]


# Czech batch. `pro` appears in every story (batch-universal connective);
# only story A is genuinely about agent tooling (nastroje/agenty), only
# story B about billing (fakturace).
texts = [
    "Nastroje pro agenty a jejich orchestrace pro produkci",
    "Fakturace pro zakazniky a mesicni vyuctovani pro tenant",
    "Reporting pro management a export pro audit",
]
m = modules(texts)
# storyA matches the agent-tooling slug on nastroje/agenty, NOT on `pro`.
print("czechA=" + (",".join(m[0]) or "_none_"))
# storyB matches the billing slug on fakturace, NOT on `pro`.
print("czechB=" + (",".join(m[1]) or "_none_"))
# storyC is about neither module → no match (proves `pro` alone matches nothing).
print("czechC=" + (",".join(m[2]) or "_none_"))

# N == 1 degeneracy: a lone story CAN match an and/pro-bearing slug on the
# connective, because df >= 2 is unsatisfiable for a single document.
solo = modules(["Sluzba pro tenant"])
print("solo=" + (",".join(solo[0]) or "_none_"))

# Optional config override drops `pro` deterministically even for the lone story.
solo_cfg = modules(["Sluzba pro tenant"], extra={"pro"})
print("solo_cfg=" + (",".join(solo_cfg[0]) or "_none_"))

# KNOWN TRADE-OFF (documented at label-taxonomy.md, "Known trade-off"):
# frequency is a proxy for distinctiveness, not distinctiveness itself. On a
# small single-topic batch a genuinely distinctive term can cross df > N/2 and
# be dropped → false NEGATIVE on the correct module. This is the opposite
# failure from the `and`/`pro` case (a miss, not a false hit) and is the
# unavoidable cost of a word-list-free heuristic. Asserted here so the tradeoff
# is a tested fact, not a hidden surprise.
billing = modules(["Billing invoice generation", "Billing refund handling"])
# df("billing") = 2, N = 2 → 2 > 1 and 2 >= 2 → dropped → NO billing match.
print("billing_fn=" + (",".join(billing[0]) or "_none_"))
# Explicit escape hatch: config module_stopwords does NOT help here (billing is
# what we WANT), but a labels.modules regex or explicit module: label would.
# The frequency filter alone yields the documented miss:
PY
)"

lget() { echo "$LANG" | grep -F "$1=" | cut -d= -f2-; }

check "czech storyA matches agent-tooling slug (on nastroje/agenty, not 'pro')" \
  "14-nastroje-pro-agenty" "$(lget czechA)"
check "czech storyB matches billing slug (on fakturace, not 'pro')" \
  "15-fakturace-modul" "$(lget czechB)"
check "czech storyC matches nothing ('pro' alone is filtered)" \
  "_none_" "$(lget czechC)"
check "N=1 degeneracy: lone story falls back to plain overlap (documented)" \
  "14-nastroje-pro-agenty" "$(lget solo)"
check "config module_stopwords override drops 'pro' even for a lone story" \
  "_none_" "$(lget solo_cfg)"
check "known trade-off: distinctive term in small single-topic batch is dropped (false negative, documented)" \
  "_none_" "$(lget billing_fn)"

echo ""
echo "== type: resolution — explicit labels[] wins over text heuristic (#272) =="

# to-issues resolves `type:` with precedence: (1) an explicit in-enum
# `type:<value>` in stories[].labels[] wins; (2) otherwise the text-heuristic
# regex table (label-taxonomy.md "Type Inference Table") is the fallback. This
# mirrors the "explicit label > inference" pattern the skill already applies to
# status: and the five prioritization dimensions — #272 extends it to type:.
#
# These assertions use their own micro-stories (NOT the shared regression
# fixture): adding a third story there would change the module-match batch
# (N=2 -> 3), perturb the df > N/2 informative-token filter, and break the
# module asserts above. `type:` is a pure per-story resolution with no batch
# dependency, so it is tested in isolation here. If SKILL.md / label-taxonomy.md
# changes the type-resolution algorithm, update this block in lockstep.
TYPE="$(python3 <<'PY'
import re

# Type Inference Table (label-taxonomy.md), first-match-wins, default feat.
# Ordered exactly as the prose table: fix -> docs -> refactor -> test -> chore
# -> future-enhancement -> default. `type_resolve` prepends the explicit-label
# precedence #272 adds on top of this heuristic.
TYPE_ENUM = {"feat", "fix", "docs", "refactor", "test", "chore", "future-enhancement"}
HEURISTIC = [
    (r"\b(fix|bug|broken|regression|hotfix|patch)\b", "fix"),
    (r"\b(docs?|readme|changelog|comment)\b", "docs"),
    (r"\b(refactor|rename|reorganize|cleanup)\b", "refactor"),
    (r"\b(test|spec|coverage)\b", "test"),
    (r"\b(chore|deps?|bump|ci|build)\b", "chore"),
    (r"\b(future|someday|eventually|parked|deferred|icebox|backlog)\b", "future-enhancement"),
]


def _heuristic(inference_text):
    text = inference_text.lower()
    for pattern, label in HEURISTIC:
        if re.search(pattern, text):
            return label
    return "feat"


def type_resolve(labels, inference_text):
    """#272 precedence: (1) explicit in-enum type:<v> in labels[] wins;
    (2) otherwise the text heuristic. An out-of-enum explicit type: is ignored
    and falls through to the heuristic (never aborts) — same tolerance the five
    prioritization dimensions apply to out-of-enum values."""
    for lab in labels:
        if lab.startswith("type:"):
            value = lab.split(":", 1)[1]
            if value in TYPE_ENUM:
                return value  # explicit in-enum wins
            # out-of-enum -> ignore, fall through to heuristic
    return _heuristic(inference_text)


# Golden (AC-4): scope says "test", but explicit type:feat wins.
print("golden=" + type_resolve(
    ["makato", "type:feat"],
    "Walking skeleton probe E2E test harness",
))
# Backward-compat (AC-5): no type: prefix, scope says "test" -> heuristic -> test.
print("legacy=" + type_resolve(
    ["makato"],
    "Walking skeleton probe E2E test harness",
))
# No type:, no keyword -> default feat.
print("default=" + type_resolve(["makato"], "Provision tenant workspaces"))
# Out-of-enum explicit type: -> ignored, falls to heuristic (here: fix).
print("bogus=" + type_resolve(["makato", "type:bogus"], "Fix the broken login"))
# Explicit type: on a fix-keyword story still wins (explicit > inference).
print("explicit_over_fix=" + type_resolve(["makato", "type:chore"], "Fix the broken login"))
PY
)"

tget() { echo "$TYPE" | grep -F "$1=" | cut -d= -f2-; }

check "golden (AC-4): explicit type:feat beats 'test' keyword" "feat" "$(tget golden)"
check "backward-compat (AC-5): no prefix -> heuristic infers 'test'" "test" "$(tget legacy)"
check "no prefix, no keyword -> default feat" "feat" "$(tget default)"
check "out-of-enum type:bogus -> falls through to heuristic (fix)" "fix" "$(tget bogus)"
check "explicit type:chore wins over 'fix' keyword (explicit > inference)" "chore" "$(tget explicit_over_fix)"

echo ""
echo "to-issues v2.0-schema smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
