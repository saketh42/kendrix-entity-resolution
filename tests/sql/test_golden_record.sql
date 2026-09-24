-- =============================================================================
-- test_golden_record.sql
-- Purpose : Data tests for sql/07_golden_record.sql.
--           Every test returns FAILURE rows: 0 rows = PASS.
--           The last query runs all tests at once and returns
--           test_name + failure_count (all 0 = everything passes).
-- Owner   : Data Engineer (Shubham)
-- Inputs  : CURATED.ENTITY_XREF, CURATED.MASTER_ORGANISATION,
--           CURATED.V_ENTITY_LINEAGE, CURATED.MATCH_DECISION,
--           CURATED.CANDIDATE_PAIR, STAGING.ORGANISATION_STD,
--           AUDIT.EXCEPTION_QUEUE
-- Outputs : None (read-only queries).
-- =============================================================================

USE DATABASE KENDRIX;

-- Test: record_in_xref_once -- every staging record is in ENTITY_XREF exactly
-- once. Fails on staging records missing or duplicated in XREF, and on XREF
-- records that do not exist in staging.
SELECT 'count_not_1' AS problem, s.RECORD_KEY, COUNT(x.RECORD_KEY) AS xref_rows
FROM STAGING.ORGANISATION_STD s
LEFT JOIN CURATED.ENTITY_XREF x ON x.RECORD_KEY = s.RECORD_KEY
GROUP BY s.RECORD_KEY
HAVING COUNT(x.RECORD_KEY) <> 1
UNION ALL
SELECT 'xref_not_in_staging', x.RECORD_KEY, NULL
FROM CURATED.ENTITY_XREF x
LEFT JOIN STAGING.ORGANISATION_STD s ON s.RECORD_KEY = x.RECORD_KEY
WHERE s.RECORD_KEY IS NULL;

-- Test: xref_master_exists -- every XREF MASTER_ID has a master record.
SELECT x.MASTER_ID, x.RECORD_KEY
FROM CURATED.ENTITY_XREF x
LEFT JOIN CURATED.MASTER_ORGANISATION m ON m.MASTER_ID = x.MASTER_ID
WHERE m.MASTER_ID IS NULL;

-- Test: master_has_members -- every master has at least one XREF row.
SELECT m.MASTER_ID, m.MASTER_NAME
FROM CURATED.MASTER_ORGANISATION m
LEFT JOIN CURATED.ENTITY_XREF x ON x.MASTER_ID = m.MASTER_ID
WHERE x.MASTER_ID IS NULL;

-- Test: nzbn_conflict_not_queued -- a master holding two different NZBNs means
-- chaining (A-B, B-C) merged two different legal entities. That is allowed
-- to exist, but only if a human has been asked to look at it: every such
-- master needs at least one OPEN 'CHAIN_NZBN_CONFLICT' row for one of its
-- member records.
SELECT m.MASTER_ID, m.MASTER_NAME, m.MEMBER_COUNT, m.MIN_LINK_CONFIDENCE
FROM CURATED.MASTER_ORGANISATION m
WHERE m.NZBN_CONFLICT = TRUE
  AND NOT EXISTS (
      SELECT 1
      FROM CURATED.ENTITY_XREF x
      JOIN AUDIT.EXCEPTION_QUEUE q ON q.RECORD_KEY = x.RECORD_KEY
      WHERE x.MASTER_ID = m.MASTER_ID
        AND q.REASON_CODE = 'CHAIN_NZBN_CONFLICT'
        AND q.STATUS = 'OPEN');

-- Test: unmatchable_merged -- a record with no usable name (IS_MATCHABLE =
-- FALSE) is never blocked or scored, so it must always be a singleton.
SELECT x.MASTER_ID, x.RECORD_KEY, m.MEMBER_COUNT
FROM CURATED.ENTITY_XREF x
JOIN STAGING.ORGANISATION_STD s    ON s.RECORD_KEY = x.RECORD_KEY
JOIN CURATED.MASTER_ORGANISATION m ON m.MASTER_ID  = x.MASTER_ID
WHERE s.IS_MATCHABLE = FALSE
  AND m.MEMBER_COUNT > 1;

-- Test: lineage_row_count -- the lineage view has exactly one row per staging
-- record (a duplicated RAW row would multiply rows here).
SELECT (SELECT COUNT(*) FROM CURATED.V_ENTITY_LINEAGE) AS lineage_rows,
       (SELECT COUNT(*) FROM STAGING.ORGANISATION_STD) AS staging_rows
WHERE (SELECT COUNT(*) FROM CURATED.V_ENTITY_LINEAGE)
   <> (SELECT COUNT(*) FROM STAGING.ORGANISATION_STD);

-- Test: auto_match_split_across_masters -- both records of an AUTO_MATCH pair
-- belong to the same master. Fails if label propagation stopped at its
-- 30-round cap before converging.
SELECT d.PAIR_ID, p.LEFT_KEY, l.MASTER_ID AS LEFT_MASTER, p.RIGHT_KEY, r.MASTER_ID AS RIGHT_MASTER
FROM CURATED.MATCH_DECISION d
JOIN CURATED.CANDIDATE_PAIR p ON p.PAIR_ID    = d.PAIR_ID
JOIN CURATED.ENTITY_XREF l    ON l.RECORD_KEY = p.LEFT_KEY
JOIN CURATED.ENTITY_XREF r    ON r.RECORD_KEY = p.RIGHT_KEY
WHERE d.DECISION = 'AUTO_MATCH'
  AND l.MASTER_ID <> r.MASTER_ID;

-- Test: member_count_mismatch -- MEMBER_COUNT equals the master's XREF rows.
SELECT m.MASTER_ID, m.MEMBER_COUNT, COUNT(x.RECORD_KEY) AS xref_rows
FROM CURATED.MASTER_ORGANISATION m
LEFT JOIN CURATED.ENTITY_XREF x ON x.MASTER_ID = m.MASTER_ID
GROUP BY m.MASTER_ID, m.MEMBER_COUNT
HAVING m.MEMBER_COUNT <> COUNT(x.RECORD_KEY);

-- -----------------------------------------------------------------------------
-- All tests in one go: one CTE per test (same logic as above), then
-- test_name + failure_count. Every failure_count should be 0.
-- -----------------------------------------------------------------------------
WITH
record_in_xref_once AS (
    SELECT s.RECORD_KEY
    FROM STAGING.ORGANISATION_STD s
    LEFT JOIN CURATED.ENTITY_XREF x ON x.RECORD_KEY = s.RECORD_KEY
    GROUP BY s.RECORD_KEY
    HAVING COUNT(x.RECORD_KEY) <> 1
    UNION ALL
    SELECT x.RECORD_KEY
    FROM CURATED.ENTITY_XREF x
    LEFT JOIN STAGING.ORGANISATION_STD s ON s.RECORD_KEY = x.RECORD_KEY
    WHERE s.RECORD_KEY IS NULL
),
xref_master_exists AS (
    SELECT x.MASTER_ID
    FROM CURATED.ENTITY_XREF x
    LEFT JOIN CURATED.MASTER_ORGANISATION m ON m.MASTER_ID = x.MASTER_ID
    WHERE m.MASTER_ID IS NULL
),
master_has_members AS (
    SELECT m.MASTER_ID
    FROM CURATED.MASTER_ORGANISATION m
    LEFT JOIN CURATED.ENTITY_XREF x ON x.MASTER_ID = m.MASTER_ID
    WHERE x.MASTER_ID IS NULL
),
nzbn_conflict_not_queued AS (
    SELECT m.MASTER_ID
    FROM CURATED.MASTER_ORGANISATION m
    WHERE m.NZBN_CONFLICT = TRUE
      AND NOT EXISTS (
          SELECT 1
          FROM CURATED.ENTITY_XREF x
          JOIN AUDIT.EXCEPTION_QUEUE q ON q.RECORD_KEY = x.RECORD_KEY
          WHERE x.MASTER_ID = m.MASTER_ID
            AND q.REASON_CODE = 'CHAIN_NZBN_CONFLICT'
            AND q.STATUS = 'OPEN')
),
unmatchable_merged AS (
    SELECT x.RECORD_KEY
    FROM CURATED.ENTITY_XREF x
    JOIN STAGING.ORGANISATION_STD s    ON s.RECORD_KEY = x.RECORD_KEY
    JOIN CURATED.MASTER_ORGANISATION m ON m.MASTER_ID  = x.MASTER_ID
    WHERE s.IS_MATCHABLE = FALSE
      AND m.MEMBER_COUNT > 1
),
lineage_row_count AS (
    SELECT 1 AS failed
    WHERE (SELECT COUNT(*) FROM CURATED.V_ENTITY_LINEAGE)
       <> (SELECT COUNT(*) FROM STAGING.ORGANISATION_STD)
),
auto_match_split_across_masters AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.CANDIDATE_PAIR p ON p.PAIR_ID    = d.PAIR_ID
    JOIN CURATED.ENTITY_XREF l    ON l.RECORD_KEY = p.LEFT_KEY
    JOIN CURATED.ENTITY_XREF r    ON r.RECORD_KEY = p.RIGHT_KEY
    WHERE d.DECISION = 'AUTO_MATCH'
      AND l.MASTER_ID <> r.MASTER_ID
),
member_count_mismatch AS (
    SELECT m.MASTER_ID
    FROM CURATED.MASTER_ORGANISATION m
    LEFT JOIN CURATED.ENTITY_XREF x ON x.MASTER_ID = m.MASTER_ID
    GROUP BY m.MASTER_ID, m.MEMBER_COUNT
    HAVING m.MEMBER_COUNT <> COUNT(x.RECORD_KEY)
)
SELECT 'record_in_xref_once'                    AS test_name, COUNT(*) AS failure_count FROM record_in_xref_once
UNION ALL SELECT 'xref_master_exists',                  COUNT(*) FROM xref_master_exists
UNION ALL SELECT 'master_has_members',                  COUNT(*) FROM master_has_members
UNION ALL SELECT 'nzbn_conflict_not_queued',            COUNT(*) FROM nzbn_conflict_not_queued
UNION ALL SELECT 'unmatchable_merged',                  COUNT(*) FROM unmatchable_merged
UNION ALL SELECT 'lineage_row_count',                   COUNT(*) FROM lineage_row_count
UNION ALL SELECT 'auto_match_split_across_masters',     COUNT(*) FROM auto_match_split_across_masters
UNION ALL SELECT 'member_count_mismatch',               COUNT(*) FROM member_count_mismatch;
