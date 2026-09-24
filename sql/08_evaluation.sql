-- =============================================================================
-- 08_evaluation.sql
-- Purpose : Measure how good the FUZZY matcher is, using NZBN as an answer key
--           it never saw. FUZZY_SCORE / FUZZY_DECISION (sql/06) use names,
--           address and contacts only, so a shared NZBN is independent
--           evidence of "same entity" we can grade them against.
--           Produces blocking recall, precision / recall / F1 for a strict
--           (AUTO_MATCH) and a lenient (AUTO_MATCH + REVIEW) reading, a
--           threshold sweep on FUZZY_SCORE, a production safety check and
--           error examples.
-- Owner   : Data Analyst (Esha)
-- Inputs  : STAGING.ORGANISATION_STD (47,709 records, built by sql/03)
--           CURATED.CANDIDATE_PAIR   (built by sql/04)
--           CURATED.MATCH_FEATURE    (built by sql/05)
--           CURATED.MATCH_DECISION   (built by sql/06, score_v5)
-- Outputs : AUDIT.EVALUATION_RESULT  - one row per metric per run (append-only)
--           CURATED.TRUTH_PAIR       - every true pair, incl. never-blocked ones
--           CURATED.V_EVAL_EXAMPLES  - top false positives / false negatives
--           one row in AUDIT.PIPELINE_RUN (step '08_evaluation')
-- Notes   : Idempotent: EVALUATION_RESULT is created IF NOT EXISTS and each
--           run appends rows under a new RUN_ID, so runs can be compared.
--           TRUTH_PAIR and the view are rebuilt on every run.
--           Tests: tests/sql/test_evaluation.sql.
-- =============================================================================

USE DATABASE KENDRIX;

-- One RUN_ID for this run, shared by every metric row and the audit log entry.
-- SET only accepts constants or subqueries, so function calls are wrapped in (SELECT ...).
SET RUN_ID = (SELECT UUID_STRING());
SET STARTED_AT = (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
-- The matcher version being evaluated (not a version of this file), so the
-- results can be tied to the scoring rules that produced them.
SET RULE_VERSION = (SELECT MAX(RULE_VERSION) FROM CURATED.MATCH_DECISION);

-- An NZBN held by more records than this is a parent / umbrella ID (e.g. every
-- St John area committee under one legal entity), not a clean "same entity"
-- label. Same limit as ID_SHARED_MAX in sql/06.
SET MAX_TRUE_NZBN_RECORDS = 3;

-- -----------------------------------------------------------------------------
-- 1) Results table. Append-only: every run adds its own rows.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AUDIT.EVALUATION_RESULT (
    RUN_ID        VARCHAR        COMMENT 'Evaluation run that produced this row',
    EVALUATED_AT  TIMESTAMP_NTZ  COMMENT 'When the evaluation run started (same for every row of a run)',
    RULE_VERSION  VARCHAR        COMMENT 'Matching rule version that was evaluated, e.g. score_v5',
    METRIC_GROUP  VARCHAR        COMMENT 'truth / blocking / strict / lenient / sweep / production',
    METRIC        VARCHAR        COMMENT 'Metric name, e.g. precision, recall_t80',
    VALUE         NUMBER(18,4)   COMMENT 'Metric value; ratios are 0-1, counts are whole numbers',
    NOTE          VARCHAR        COMMENT 'What the metric means, in plain words'
);

-- -----------------------------------------------------------------------------
-- 2) CURATED.TRUTH_PAIR: the answer key. Built from STAGING, not from
--    CANDIDATE_PAIR, so it also holds the true pairs blocking never generated
--    (otherwise recall would only be measured on what blocking already found).
--    A real table (not TEMPORARY) because the examples view and the tests read
--    it after this session ends.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CURATED.TRUTH_PAIR AS
WITH
-- How many records carry each NZBN. Counted over ALL records (matchable or
-- not), the same way NZBN_SHARED_COUNT is counted in sql/05. NZBN is already
-- NULL unless it is '94' + 11 digits (sql/03), so every value here is valid.
nzbn_count AS (
    SELECT NZBN, COUNT(*) AS NZBN_RECORD_COUNT
    FROM STAGING.ORGANISATION_STD
    WHERE NZBN IS NOT NULL
    GROUP BY NZBN
),

-- Only matchable records: a record with no usable name is never blocked or
-- scored, so counting it as a missed match would blame the matcher unfairly.
matchable AS (
    SELECT RECORD_KEY, NZBN
    FROM STAGING.ORGANISATION_STD
    WHERE IS_MATCHABLE
      AND NZBN IS NOT NULL
),

-- Every two matchable records sharing a non-umbrella NZBN.
-- LEFT_KEY < RIGHT_KEY: same convention as CANDIDATE_PAIR, so they join 1:1.
truth AS (
    SELECT l.RECORD_KEY AS LEFT_KEY, r.RECORD_KEY AS RIGHT_KEY, l.NZBN, c.NZBN_RECORD_COUNT
    FROM matchable l
    JOIN matchable r  ON r.NZBN = l.NZBN AND l.RECORD_KEY < r.RECORD_KEY
    JOIN nzbn_count c ON c.NZBN = l.NZBN
    WHERE c.NZBN_RECORD_COUNT <= $MAX_TRUE_NZBN_RECORDS
)

SELECT
    t.LEFT_KEY::VARCHAR                             AS LEFT_KEY,
    t.RIGHT_KEY::VARCHAR                            AS RIGHT_KEY,
    t.NZBN::VARCHAR                                 AS NZBN,
    t.NZBN_RECORD_COUNT::NUMBER                     AS NZBN_RECORD_COUNT,
    -- NULL = blocking never generated this pair.
    p.PAIR_ID::VARCHAR                              AS PAIR_ID,
    (p.PAIR_ID IS NOT NULL)::BOOLEAN                AS IN_CANDIDATES,
    -- Found by at least one block other than NZBN (name, address, contact...).
    -- Only these pairs are fair game for the fuzzy matcher, see section 3.
    COALESCE(NOT p.ONLY_NZBN_BLOCK, FALSE)::BOOLEAN AS FOUND_WITHOUT_NZBN,
    p.BLOCK_TYPES::ARRAY                            AS BLOCK_TYPES,
    d.FUZZY_SCORE                                   AS FUZZY_SCORE,
    d.FUZZY_DECISION::VARCHAR                       AS FUZZY_DECISION,
    $RUN_ID::VARCHAR                                AS RUN_ID
FROM truth t
LEFT JOIN CURATED.CANDIDATE_PAIR p ON p.LEFT_KEY = t.LEFT_KEY AND p.RIGHT_KEY = t.RIGHT_KEY
LEFT JOIN CURATED.MATCH_DECISION d ON d.PAIR_ID  = p.PAIR_ID;

-- -----------------------------------------------------------------------------
-- 3) Evaluable candidate pairs: the pairs where a fuzzy prediction can be
--    graded right or wrong.
--    - Both records have an NZBN. If one side has none, the key cannot say
--      whether a match is right or wrong, so the pair is left out.
--    - Not an umbrella pair (same NZBN but on > MAX_TRUE_NZBN_RECORDS records):
--      branches of one legal entity are neither clearly the same nor clearly
--      different, so they count as neither TP nor FP.
--    - ONLY_NZBN_BLOCK = FALSE: a pair found ONLY through the NZBN block exists
--      because of the answer key itself; letting the fuzzy matcher score it
--      would leak the key back in. Such true pairs still count as FN.
--    TEMPORARY: working data for this session only (same pattern as sql/06).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE CURATED.TMP_EVAL_PAIR AS
SELECT
    p.PAIR_ID,
    p.LEFT_KEY,
    p.RIGHT_KEY,
    -- In TRUTH_PAIR = same non-umbrella NZBN = true match.
    (t.LEFT_KEY IS NOT NULL)::BOOLEAN AS IS_TRUE,
    d.FUZZY_SCORE,
    d.FUZZY_DECISION
FROM CURATED.CANDIDATE_PAIR p
JOIN CURATED.MATCH_DECISION d   ON d.PAIR_ID    = p.PAIR_ID
JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
LEFT JOIN CURATED.TRUTH_PAIR t  ON t.LEFT_KEY   = p.LEFT_KEY AND t.RIGHT_KEY = p.RIGHT_KEY
WHERE p.ONLY_NZBN_BLOCK = FALSE
  AND l.NZBN IS NOT NULL
  AND r.NZBN IS NOT NULL
  -- Same NZBN but not in TRUTH_PAIR can only mean an umbrella NZBN (every
  -- candidate record is matchable): drop it, it is neither TP nor FP.
  AND NOT (l.NZBN = r.NZBN AND t.LEFT_KEY IS NULL);

-- -----------------------------------------------------------------------------
-- 4) Metrics -> AUDIT.EVALUATION_RESULT.
--    Recall always divides by ALL true pairs (incl. never-blocked ones), so it
--    is directly comparable with blocking_recall_without_nzbn, its ceiling.
--    NULLIF on every denominator: a threshold that predicts nothing gives a
--    NULL precision, not a divide-by-zero error.
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.EVALUATION_RESULT (RUN_ID, EVALUATED_AT, RULE_VERSION, METRIC_GROUP, METRIC, VALUE, NOTE)
WITH
truth_stats AS (
    SELECT COUNT(*)                     AS N_TRUE,
           COUNT_IF(IN_CANDIDATES)      AS N_BLOCKED,
           COUNT_IF(FOUND_WITHOUT_NZBN) AS N_BLOCKED_WITHOUT_NZBN
    FROM CURATED.TRUTH_PAIR
),

-- Strict = only what the fuzzy matcher would merge by itself.
-- Lenient = also what it would send to a human (best case after review).
predicted AS (
    SELECT 'strict' AS MODE, IS_TRUE FROM CURATED.TMP_EVAL_PAIR WHERE FUZZY_DECISION = 'AUTO_MATCH'
    UNION ALL
    SELECT 'lenient',        IS_TRUE FROM CURATED.TMP_EVAL_PAIR WHERE FUZZY_DECISION IN ('AUTO_MATCH', 'REVIEW')
),
-- VALUES list so a mode with no predictions still gets a row (TP = FP = 0).
decision_confusion AS (
    SELECT m.MODE AS METRIC_GROUP, '' AS SUFFIX,
           COUNT_IF(p.IS_TRUE) AS TP, COUNT_IF(NOT p.IS_TRUE) AS FP
    FROM (SELECT * FROM VALUES ('strict'), ('lenient') AS t(MODE)) m
    LEFT JOIN predicted p ON p.MODE = m.MODE
    GROUP BY m.MODE
),

-- Threshold sweep on FUZZY_SCORE alone (no gates), to see where precision and
-- recall trade off and whether the current thresholds (75 / 85) sit well.
sweep_confusion AS (
    SELECT 'sweep' AS METRIC_GROUP, '_t' || t.THRESHOLD AS SUFFIX,
           COUNT_IF(e.IS_TRUE) AS TP, COUNT_IF(NOT e.IS_TRUE) AS FP
    FROM (SELECT * FROM VALUES (50), (55), (60), (65), (70), (75), (80), (85), (90), (95) AS t(THRESHOLD)) t
    LEFT JOIN CURATED.TMP_EVAL_PAIR e ON e.FUZZY_SCORE >= t.THRESHOLD
    GROUP BY t.THRESHOLD
),

-- FN = true pairs not predicted, incl. those blocking never generated.
prf AS (
    SELECT c.METRIC_GROUP, c.SUFFIX, c.TP, c.FP,
           ts.N_TRUE - c.TP                       AS FN,
           c.TP / NULLIF(c.TP + c.FP, 0)          AS PRECISION_,
           c.TP / NULLIF(ts.N_TRUE, 0)            AS RECALL_
    FROM (SELECT * FROM decision_confusion UNION ALL SELECT * FROM sweep_confusion) c
    CROSS JOIN truth_stats ts
),
prf_f1 AS (
    SELECT p.*, 2 * PRECISION_ * RECALL_ / NULLIF(PRECISION_ + RECALL_, 0) AS F1
    FROM prf p
),

-- Production safety check: an AUTO_MATCH between two DIFFERENT NZBNs would
-- merge two legal entities; sql/06 rule b must prevent it, so this must be 0.
prod AS (
    SELECT COUNT_IF(f.NZBN_EQ = FALSE) AS N_CONFLICT,
           COUNT_IF(f.NZBN_EQ = TRUE)  AS N_EQUAL
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION = 'AUTO_MATCH'
),

metrics AS (
    SELECT 'truth' AS METRIC_GROUP, 'total_true_pairs' AS METRIC, N_TRUE AS VALUE,
           'Pairs of matchable records sharing an NZBN held by at most 3 records' AS NOTE
    FROM truth_stats
    UNION ALL
    SELECT 'truth', 'evaluable_candidate_pairs', (SELECT COUNT(*) FROM CURATED.TMP_EVAL_PAIR),
           'Candidate pairs (not NZBN-only) where both sides have an NZBN, umbrella NZBNs excluded'
    UNION ALL
    SELECT 'blocking', 'blocking_recall_all', N_BLOCKED / NULLIF(N_TRUE, 0),
           'Share of true pairs present in CANDIDATE_PAIR through any block'
    FROM truth_stats
    UNION ALL
    SELECT 'blocking', 'blocking_recall_without_nzbn', N_BLOCKED_WITHOUT_NZBN / NULLIF(N_TRUE, 0),
           'Share of true pairs found by a non-NZBN block: recall ceiling for fuzzy matching'
    FROM truth_stats

    -- strict / lenient: counts and ratios.
    UNION ALL SELECT METRIC_GROUP, 'tp', TP, 'Predicted match, same NZBN'
              FROM prf_f1 WHERE METRIC_GROUP <> 'sweep'
    UNION ALL SELECT METRIC_GROUP, 'fp', FP, 'Predicted match, different NZBNs'
              FROM prf_f1 WHERE METRIC_GROUP <> 'sweep'
    UNION ALL SELECT METRIC_GROUP, 'fn', FN, 'True pair not predicted (incl. never blocked)'
              FROM prf_f1 WHERE METRIC_GROUP <> 'sweep'
    UNION ALL SELECT METRIC_GROUP, 'precision', PRECISION_, 'TP / (TP + FP)'
              FROM prf_f1 WHERE METRIC_GROUP <> 'sweep'
    UNION ALL SELECT METRIC_GROUP, 'recall', RECALL_, 'TP / total_true_pairs'
              FROM prf_f1 WHERE METRIC_GROUP <> 'sweep'
    UNION ALL SELECT METRIC_GROUP, 'f1', F1, 'Harmonic mean of precision and recall'
              FROM prf_f1 WHERE METRIC_GROUP <> 'sweep'

    -- sweep: precision / recall / F1 per threshold (FUZZY_SCORE >= threshold).
    UNION ALL SELECT 'sweep', 'precision' || SUFFIX, PRECISION_, 'FUZZY_SCORE >= threshold, no gates'
              FROM prf_f1 WHERE METRIC_GROUP = 'sweep'
    UNION ALL SELECT 'sweep', 'recall' || SUFFIX, RECALL_, 'FUZZY_SCORE >= threshold, no gates'
              FROM prf_f1 WHERE METRIC_GROUP = 'sweep'
    UNION ALL SELECT 'sweep', 'f1' || SUFFIX, F1, 'FUZZY_SCORE >= threshold, no gates'
              FROM prf_f1 WHERE METRIC_GROUP = 'sweep'

    UNION ALL
    SELECT 'production', 'prod_auto_nzbn_conflict', N_CONFLICT,
           'Production AUTO_MATCH pairs with different NZBNs (must be 0)'
    FROM prod
    UNION ALL
    SELECT 'production', 'prod_auto_nzbn_equal', N_EQUAL,
           'Production AUTO_MATCH pairs with the same NZBN'
    FROM prod
)

SELECT $RUN_ID, $STARTED_AT, $RULE_VERSION,
       METRIC_GROUP, METRIC, VALUE::NUMBER(18,4), NOTE
FROM metrics;

-- -----------------------------------------------------------------------------
-- 5) CURATED.V_EVAL_EXAMPLES: the errors worth explaining.
--    FALSE_POSITIVE: fuzzy predicted a match (AUTO_MATCH or REVIEW) but the
--      NZBNs differ; highest FUZZY_SCORE first = the most confident mistakes.
--      Different NZBNs cannot share the NZBN block, so these were all found
--      by a non-NZBN block.
--    FALSE_NEGATIVE: true pairs the fuzzy matcher scored NO_MATCH, lowest
--      FUZZY_SCORE first = the pairs it missed by the widest margin.
--    TOP_REASONS is the production column: for ID-rule pairs it starts with
--      the rule name, followed by the fuzzy features that added the most.
--    PAIR_ID breaks ties so the examples are the same on every run.
--    A view (not a table) so it always reflects the latest sql/06 run.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW CURATED.V_EVAL_EXAMPLES
    COMMENT = 'Top 10 fuzzy false positives and 10 lowest-scored true pairs (false negatives), NZBN answer key'
AS
WITH
false_positive AS (
    SELECT 'FALSE_POSITIVE' AS EXAMPLE_TYPE,
           ROW_NUMBER() OVER (ORDER BY d.FUZZY_SCORE DESC, d.PAIR_ID) AS EXAMPLE_RANK,
           p.PAIR_ID, p.LEFT_KEY, p.RIGHT_KEY,
           d.FUZZY_SCORE, d.FUZZY_DECISION, d.TOP_REASONS, p.BLOCK_TYPES
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = d.PAIR_ID
    JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
    JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
    WHERE l.NZBN <> r.NZBN
      AND d.FUZZY_DECISION IN ('AUTO_MATCH', 'REVIEW')
    QUALIFY EXAMPLE_RANK <= 10
),
false_negative AS (
    SELECT 'FALSE_NEGATIVE' AS EXAMPLE_TYPE,
           ROW_NUMBER() OVER (ORDER BY t.FUZZY_SCORE, t.PAIR_ID) AS EXAMPLE_RANK,
           t.PAIR_ID, t.LEFT_KEY, t.RIGHT_KEY,
           t.FUZZY_SCORE, t.FUZZY_DECISION, d.TOP_REASONS, t.BLOCK_TYPES
    FROM CURATED.TRUTH_PAIR t
    JOIN CURATED.MATCH_DECISION d ON d.PAIR_ID = t.PAIR_ID
    WHERE t.FUZZY_DECISION = 'NO_MATCH'
    QUALIFY EXAMPLE_RANK <= 10
),
examples AS (
    SELECT * FROM false_positive
    UNION ALL
    SELECT * FROM false_negative
)
SELECT
    e.EXAMPLE_TYPE,
    e.EXAMPLE_RANK,
    e.PAIR_ID,
    e.LEFT_KEY,
    l.NAME_RAW       AS LEFT_NAME,
    e.RIGHT_KEY,
    r.NAME_RAW       AS RIGHT_NAME,
    e.FUZZY_SCORE,
    e.FUZZY_DECISION,
    e.TOP_REASONS,
    e.BLOCK_TYPES
FROM examples e
JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = e.LEFT_KEY
JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = e.RIGHT_KEY;

-- -----------------------------------------------------------------------------
-- 6) Audit log row. SUCCESS only if there is an answer key at all and no
--    production AUTO_MATCH merges two different NZBNs.
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.PIPELINE_RUN (RUN_ID, STEP, STARTED_AT, FINISHED_AT, ROWS_OUT, RULE_VERSION, STATUS, NOTES)
SELECT $RUN_ID, '08_evaluation',
       $STARTED_AT,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
       COUNT(*), $RULE_VERSION,
       IFF(MAX(IFF(METRIC = 'total_true_pairs', VALUE, NULL)) > 0
           AND MAX(IFF(METRIC = 'prod_auto_nzbn_conflict', VALUE, NULL)) = 0, 'SUCCESS', 'FAIL'),
       'true_pairs=' || MAX(IFF(METRIC = 'total_true_pairs', VALUE, NULL))::NUMBER
           || ', strict_precision=' || COALESCE(MAX(IFF(METRIC_GROUP = 'strict' AND METRIC = 'precision', VALUE, NULL))::VARCHAR, 'NULL')
           || ', strict_recall='    || COALESCE(MAX(IFF(METRIC_GROUP = 'strict' AND METRIC = 'recall', VALUE, NULL))::VARCHAR, 'NULL')
FROM AUDIT.EVALUATION_RESULT
WHERE RUN_ID = $RUN_ID;

-- -----------------------------------------------------------------------------
-- 7) Summary (last, so this result is what you see in Snowsight).
-- -----------------------------------------------------------------------------
SELECT METRIC_GROUP, METRIC, VALUE, NOTE
FROM AUDIT.EVALUATION_RESULT
WHERE RUN_ID = $RUN_ID
ORDER BY METRIC_GROUP, METRIC;
