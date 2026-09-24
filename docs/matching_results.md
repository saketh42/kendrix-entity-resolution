# Matching results

Produced by `sql/08_evaluation.sql`. Numbers come from `AUDIT.EVALUATION_RESULT` (rule version **score_v5**), and the error examples come from `CURATED.V_EVAL_EXAMPLES`. Tests: `tests/sql/test_evaluation.sql`.

## 1. How we evaluate

- **Answer key = NZBN.** The fuzzy matcher (`FUZZY_SCORE` / `FUZZY_DECISION`) looks only at names, addresses and contacts. It never sees an NZBN, so a shared NZBN gives us an independent check on whether two records are the same entity.
- **True pair:** two matchable records that share a valid NZBN (`94` + 11 digits), where that NZBN is on **at most 3 records**. An NZBN on more records than that belongs to a parent or umbrella body (for example branches or area committees), so we don't treat it as a clean "same entity" label.
- **Evaluable pair:** both records have an NZBN, so we can tell whether a match is right (same NZBN) or wrong (different NZBNs). Pairs where only one side has an NZBN are left out, and so are pairs that share an umbrella NZBN.
- **No leaking the key:** pairs that blocking found *only* through the NZBN block don't count as fuzzy predictions. They still count as missed true pairs. Recall is measured against **all** true pairs, including ones blocking never generated.
- **Strict** = `FUZZY_DECISION = 'AUTO_MATCH'`. **Lenient** = `AUTO_MATCH` or `REVIEW` (the best we could reach after human review).

## 2. Results

**Answer key and blocking**

| Metric | Value |
|---|---|
| True pairs | 1,142 |
| Evaluable candidate pairs | 87,024 |
| Blocking recall, all blocks (incl. NZBN) | 100% |
| Blocking recall without NZBN (fuzzy recall ceiling) | 89.3% |

Blocking recall: 100% overall, 89.3% without NZBN blocks (10.7% of true pairs unreachable by fuzzy matching).

**Fuzzy matcher (no identifiers)**

| Mode | TP | FP | FN | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|---:|
| Strict (AUTO_MATCH) | 282 | 141 | 860 | 0.667 | 0.247 | 0.360 |
| Lenient (AUTO + REVIEW) | 526 | 3,305 | 616 | 0.137 | 0.461 | 0.212 |

**Production (identifier rules + fuzzy)**

| Check | Value |
|---|---:|
| AUTO_MATCH pairs with different NZBNs (must be 0) | 0 |
| AUTO_MATCH pairs confirmed by the same NZBN | 951 |

## 3. Threshold choice and why

Stored threshold sweep values (`FUZZY_SCORE >= t`, no gates).

| Threshold | Precision | Recall | F1 |
|---:|---:|---:|---:|
| 75 | 0.1373 | 0.4606 | 0.2115 |
| 80 | 0.1890 | 0.3573 | 0.2472 |
| **85** | **0.2633** | **0.2680** | **0.2656** (best) |
| 90 | 0.4350 | 0.1874 | 0.2619 |
| 95 | 0.6287 | 0.1305 | 0.2161 |

- **AUTO_MATCH at 85.** 85 gives the best F1 of any threshold on the score alone. On top of the score, AUTO_MATCH also requires a strong name, a second non-name piece of evidence and at least 75% word overlap. At t85, strict precision with gates is **0.6667 vs 0.2633 without gates: ~2.5x precision from the gates**, with recall falling from 26.8% to 24.7%. Raising the threshold to 95 instead would give similar precision (63%) but only about half the recall (13%).
- **REVIEW at 75.** This catches 46% of true pairs for human review. Going lower would mostly add false positives: at 75, precision is already down to 14%.

## 4. Error examples

Real examples from `CURATED.V_EVAL_EXAMPLES`. Organisation names only; no personal data.

**False positives (fuzzy AUTO, different NZBNs)**

- Antarctic Heritage Trust <-> Antarctic Heritage Trust Limited; West Otago Health Trust <-> West Otago Health Limited; Teviot Valley Rest Home Trust <-> Teviot Valley Rest Home Limited. Pattern: a trust and its operating company share name/email/address but are separate legal entities. Production routes them to REVIEW via `ID_CONFLICT_REVIEW`, never auto-merged (`prod_auto_nzbn_conflict = 0`).
- Q-Youth Incorporated -> Q-Youth Charitable Trust; RNZSPCA Inc <-> RNZSPCA: probable re-registrations, arguably true matches, so strict precision is slightly understated.

**False negatives (same NZBN, low name score)**

- Rata Foundation Limited <-> The Canterbury Community Trust Charities Limited: organisation rename.
- The Baptist Union of New Zealand <-> Flaxmere Baptist Church; Community Patrols of NZ Charitable Trust <-> Whangamata Community Patrol Inc: umbrella <-> member.
- The Robin Hood Foundation <-> The Lawaid Foundation: clearly different organisations sharing an NZBN = answer-key noise, so recall is understated.

All of these false negatives go to REVIEW in production via `ID_MATCH_NAME_DIFFERS`.

**Data-quality find:** one charity record's name is "CC50006" (a registration number stored as the name).

Next improvement: a Trust<->Limited related-entity rule and alias/former-name lookup.

## 5. Limitations

- **NZBN measures legal identity, not organisational identity.** A legal-form change (Inc → Trust with a new NZBN) counts as a false positive, so the true precision is probably **higher** than the 67% reported. On the other hand, a re-registration that keeps the same NZBN counts as the same entity even if the organisation changed.
- **Recall ceiling:** 10.7% of true pairs share no non-NZBN block, so the fuzzy matcher never sees them. Fuzzy recall can't go above 89.3%.
- **Template-named branches** (Methodist parishes, St John committees) look alike by name and address but are different entities.
- **Coverage:** the evaluation only covers records that have an NZBN. Precision on records without one may differ.
