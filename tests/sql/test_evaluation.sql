-- =============================================================================
-- test_evaluation.sql
-- Purpose : Data tests for sql/08_evaluation.sql.
--           Every test returns FAILURE rows: 0 rows = PASS.
--           The last query runs all tests at once and returns
--           test_name + failure_count (all 0 = everything passes).
-- Owner   : Data Analyst (Esha)
-- Inputs  : AUDIT.EVALUATION_RESULT (latest run), CURATED.MATCH_DECISION,
--           CURATED.MATCH_FEATURE
-- Outputs : None (read-only queries; one session variable).
-- =============================================================================

USE DATABASE KENDRIX;

-- Tests check the most recent evaluation run only: older runs stay in the
-- table for comparison and may come from older scoring rules.
-- NULL (no run yet) makes metrics_present and sweep_complete fail, as they should.
SET EVAL_RUN_ID = (SELECT RUN_ID FROM AUDIT.EVALUATION_RESULT ORDER BY EVALUATED_AT DESC, RUN_ID LIMIT 1);

-- Test: metrics_present -- the headline metrics exist and are not NULL.
-- A NULL precision here means the matcher predicted nothing at all.
SELECT e.METRIC_GROUP, e.METRIC, r.VALUE
FROM (SELECT * FROM VALUES ('strict', 'precision'), ('strict', 'recall'),
                           ('lenient', 'precision'), ('lenient', 'recall') AS t(METRIC_GROUP, METRIC)) e
LEFT JOIN AUDIT.EVALUATION_RESULT r
       ON r.RUN_ID = $EVAL_RUN_ID AND r.METRIC_GROUP = e.METRIC_GROUP AND r.METRIC = e.METRIC
WHERE r.VALUE IS NULL;

-- Test: metric_range -- every ratio (precision / recall / F1, incl. sweep and
-- blocking recall) lies between 0 and 1. A NULL (nothing predicted at a high
-- sweep threshold) is allowed. REGEXP_LIKE matches the whole string.
SELECT METRIC_GROUP, METRIC, VALUE
FROM AUDIT.EVALUATION_RESULT
WHERE RUN_ID = $EVAL_RUN_ID
  AND REGEXP_LIKE(METRIC, '(precision|recall|f1)(_t[0-9]+)?|blocking_recall_.*')
  AND (VALUE < 0 OR VALUE > 1);

-- Test: prod_auto_on_nzbn_conflict -- no production AUTO_MATCH joins two
-- different NZBNs (that would merge two legal entities). Reads the decision
-- table directly, not the stored metric, so it also holds after a re-score.
SELECT d.PAIR_ID, d.DECISION_PATH, d.SCORE
FROM CURATED.MATCH_DECISION d
JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
WHERE d.DECISION = 'AUTO_MATCH'
  AND f.NZBN_EQ = FALSE;

-- Test: sweep_complete -- precision, recall and F1 each have all 10
-- thresholds (50, 55, ..., 95).
SELECT m.METRIC, COUNT(DISTINCT REGEXP_SUBSTR(r.METRIC, '[0-9]+$')) AS thresholds
FROM (SELECT * FROM VALUES ('precision'), ('recall'), ('f1') AS t(METRIC)) m
LEFT JOIN AUDIT.EVALUATION_RESULT r
       ON r.RUN_ID = $EVAL_RUN_ID
      AND r.METRIC_GROUP = 'sweep'
      AND REGEXP_LIKE(r.METRIC, m.METRIC || '_t[0-9]+')
GROUP BY m.METRIC
HAVING COUNT(DISTINCT REGEXP_SUBSTR(r.METRIC, '[0-9]+$')) <> 10;

-- -----------------------------------------------------------------------------
-- All tests in one go: one CTE per test (same logic as above), then
-- test_name + failure_count. Every failure_count should be 0.
-- -----------------------------------------------------------------------------
WITH
metrics_present AS (
    SELECT e.METRIC
    FROM (SELECT * FROM VALUES ('strict', 'precision'), ('strict', 'recall'),
                               ('lenient', 'precision'), ('lenient', 'recall') AS t(METRIC_GROUP, METRIC)) e
    LEFT JOIN AUDIT.EVALUATION_RESULT r
           ON r.RUN_ID = $EVAL_RUN_ID AND r.METRIC_GROUP = e.METRIC_GROUP AND r.METRIC = e.METRIC
    WHERE r.VALUE IS NULL
),
metric_range AS (
    SELECT METRIC
    FROM AUDIT.EVALUATION_RESULT
    WHERE RUN_ID = $EVAL_RUN_ID
      AND REGEXP_LIKE(METRIC, '(precision|recall|f1)(_t[0-9]+)?|blocking_recall_.*')
      AND (VALUE < 0 OR VALUE > 1)
),
prod_auto_on_nzbn_conflict AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION = 'AUTO_MATCH'
      AND f.NZBN_EQ = FALSE
),
sweep_complete AS (
    SELECT m.METRIC
    FROM (SELECT * FROM VALUES ('precision'), ('recall'), ('f1') AS t(METRIC)) m
    LEFT JOIN AUDIT.EVALUATION_RESULT r
           ON r.RUN_ID = $EVAL_RUN_ID
          AND r.METRIC_GROUP = 'sweep'
          AND REGEXP_LIKE(r.METRIC, m.METRIC || '_t[0-9]+')
    GROUP BY m.METRIC
    HAVING COUNT(DISTINCT REGEXP_SUBSTR(r.METRIC, '[0-9]+$')) <> 10
)
SELECT 'metrics_present'                AS test_name, COUNT(*) AS failure_count FROM metrics_present
UNION ALL SELECT 'metric_range',                  COUNT(*) FROM metric_range
UNION ALL SELECT 'prod_auto_on_nzbn_conflict',    COUNT(*) FROM prod_auto_on_nzbn_conflict
UNION ALL SELECT 'sweep_complete',                COUNT(*) FROM sweep_complete;
