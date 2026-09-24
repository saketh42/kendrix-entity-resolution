-- =============================================================================
-- test_candidates.sql
-- Purpose : Data tests for sql/04_candidates.sql.
--           Every test returns FAILURE rows: 0 rows = PASS.
--           The last query runs all tests at once and returns
--           test_name + failure_count (all 0 = everything passes).
-- Owner   : Data Engineer (Shubham)
-- Inputs  : CURATED.CANDIDATE_PAIR, CURATED.BLOCK_KEY, CURATED.BLOCK_SKIPPED,
--           STAGING.ORGANISATION_STD
-- Outputs : None (read-only queries).
-- =============================================================================

USE DATABASE KENDRIX;

-- Test: self_pair -- a record must never be paired with itself.
SELECT PAIR_ID, LEFT_KEY, RIGHT_KEY
FROM CURATED.CANDIDATE_PAIR
WHERE LEFT_KEY = RIGHT_KEY;

-- Test: wrong_order -- LEFT_KEY < RIGHT_KEY always, otherwise (A,B) and (B,A)
-- could both exist.
SELECT PAIR_ID, LEFT_KEY, RIGHT_KEY
FROM CURATED.CANDIDATE_PAIR
WHERE LEFT_KEY >= RIGHT_KEY;

-- Test: duplicate_pair_id -- one row per pair.
SELECT PAIR_ID, COUNT(*) AS n
FROM CURATED.CANDIDATE_PAIR
GROUP BY PAIR_ID
HAVING COUNT(*) > 1;

-- Test: pair_with_unmatchable_record -- records with no usable name must not
-- be in any pair.
SELECT p.PAIR_ID, s.RECORD_KEY
FROM CURATED.CANDIDATE_PAIR p
JOIN STAGING.ORGANISATION_STD s
  ON s.RECORD_KEY IN (p.LEFT_KEY, p.RIGHT_KEY)
WHERE NOT s.IS_MATCHABLE;

-- Test: pair_without_block -- every pair must come from at least one block.
SELECT PAIR_ID, BLOCK_TYPES, BLOCK_COUNT
FROM CURATED.CANDIDATE_PAIR
WHERE BLOCK_COUNT IS NULL OR BLOCK_COUNT = 0;

-- Test: keys_not_in_staging -- both keys must exist in ORGANISATION_STD.
SELECT p.PAIR_ID, p.LEFT_KEY, p.RIGHT_KEY
FROM CURATED.CANDIDATE_PAIR p
LEFT JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
LEFT JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
WHERE l.RECORD_KEY IS NULL OR r.RECORD_KEY IS NULL;

-- Test: oversized_block_used -- rebuild the blocks each pair really shares from
-- BLOCK_KEY (which keeps ALL keys). A pair fails if every block it shares is in
-- BLOCK_SKIPPED, i.e. it could only have come from an oversized block.
WITH shared AS (
    SELECT p.PAIR_ID, l.BLOCK_TYPE, l.BLOCK_VALUE,
           (s.BLOCK_TYPE IS NOT NULL) AS IS_SKIPPED
    FROM CURATED.CANDIDATE_PAIR p
    JOIN CURATED.BLOCK_KEY l
      ON l.RECORD_KEY = p.LEFT_KEY
    JOIN CURATED.BLOCK_KEY r
      ON  r.RECORD_KEY  = p.RIGHT_KEY
      AND r.BLOCK_TYPE  = l.BLOCK_TYPE
      AND r.BLOCK_VALUE = l.BLOCK_VALUE
    LEFT JOIN CURATED.BLOCK_SKIPPED s
      ON  s.BLOCK_TYPE  = l.BLOCK_TYPE
      AND s.BLOCK_VALUE = l.BLOCK_VALUE
)
SELECT PAIR_ID, ARRAY_AGG(BLOCK_TYPE || '=' || BLOCK_VALUE) AS SHARED_BLOCKS
FROM shared
GROUP BY PAIR_ID
HAVING COUNT_IF(NOT IS_SKIPPED) = 0;

-- Test: nzbn_pairs_are_linked -- every two matchable records with the same NZBN
-- must be a candidate pair, unless that NZBN block was skipped as oversized.
-- (Equality on NZBN already excludes NULLs.)
SELECT a.RECORD_KEY AS LEFT_KEY, b.RECORD_KEY AS RIGHT_KEY, a.NZBN
FROM STAGING.ORGANISATION_STD a
JOIN STAGING.ORGANISATION_STD b
  ON  b.NZBN = a.NZBN
  AND a.RECORD_KEY < b.RECORD_KEY
WHERE a.IS_MATCHABLE AND b.IS_MATCHABLE
  AND NOT EXISTS (SELECT 1 FROM CURATED.BLOCK_SKIPPED s
                  WHERE s.BLOCK_TYPE = 'NZBN' AND s.BLOCK_VALUE = a.NZBN)
  AND NOT EXISTS (SELECT 1 FROM CURATED.CANDIDATE_PAIR p
                  WHERE p.LEFT_KEY = a.RECORD_KEY AND p.RIGHT_KEY = b.RECORD_KEY);

-- -----------------------------------------------------------------------------
-- All tests in one go: one CTE per test (same logic as above), then
-- test_name + failure_count. Every failure_count should be 0.
-- -----------------------------------------------------------------------------
WITH
self_pair AS (
    SELECT PAIR_ID FROM CURATED.CANDIDATE_PAIR
    WHERE LEFT_KEY = RIGHT_KEY
),
wrong_order AS (
    SELECT PAIR_ID FROM CURATED.CANDIDATE_PAIR
    WHERE LEFT_KEY >= RIGHT_KEY
),
duplicate_pair_id AS (
    SELECT PAIR_ID FROM CURATED.CANDIDATE_PAIR
    GROUP BY PAIR_ID
    HAVING COUNT(*) > 1
),
pair_with_unmatchable_record AS (
    SELECT p.PAIR_ID
    FROM CURATED.CANDIDATE_PAIR p
    JOIN STAGING.ORGANISATION_STD s
      ON s.RECORD_KEY IN (p.LEFT_KEY, p.RIGHT_KEY)
    WHERE NOT s.IS_MATCHABLE
),
pair_without_block AS (
    SELECT PAIR_ID FROM CURATED.CANDIDATE_PAIR
    WHERE BLOCK_COUNT IS NULL OR BLOCK_COUNT = 0
),
keys_not_in_staging AS (
    SELECT p.PAIR_ID
    FROM CURATED.CANDIDATE_PAIR p
    LEFT JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
    LEFT JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
    WHERE l.RECORD_KEY IS NULL OR r.RECORD_KEY IS NULL
),
shared_blocks AS (
    SELECT p.PAIR_ID, (s.BLOCK_TYPE IS NOT NULL) AS IS_SKIPPED
    FROM CURATED.CANDIDATE_PAIR p
    JOIN CURATED.BLOCK_KEY l
      ON l.RECORD_KEY = p.LEFT_KEY
    JOIN CURATED.BLOCK_KEY r
      ON  r.RECORD_KEY  = p.RIGHT_KEY
      AND r.BLOCK_TYPE  = l.BLOCK_TYPE
      AND r.BLOCK_VALUE = l.BLOCK_VALUE
    LEFT JOIN CURATED.BLOCK_SKIPPED s
      ON  s.BLOCK_TYPE  = l.BLOCK_TYPE
      AND s.BLOCK_VALUE = l.BLOCK_VALUE
),
oversized_block_used AS (
    SELECT PAIR_ID FROM shared_blocks
    GROUP BY PAIR_ID
    HAVING COUNT_IF(NOT IS_SKIPPED) = 0
),
nzbn_pairs_are_linked AS (
    SELECT a.RECORD_KEY
    FROM STAGING.ORGANISATION_STD a
    JOIN STAGING.ORGANISATION_STD b
      ON  b.NZBN = a.NZBN
      AND a.RECORD_KEY < b.RECORD_KEY
    WHERE a.IS_MATCHABLE AND b.IS_MATCHABLE
      AND NOT EXISTS (SELECT 1 FROM CURATED.BLOCK_SKIPPED s
                      WHERE s.BLOCK_TYPE = 'NZBN' AND s.BLOCK_VALUE = a.NZBN)
      AND NOT EXISTS (SELECT 1 FROM CURATED.CANDIDATE_PAIR p
                      WHERE p.LEFT_KEY = a.RECORD_KEY AND p.RIGHT_KEY = b.RECORD_KEY)
)
SELECT 'self_pair'                    AS test_name, COUNT(*) AS failure_count FROM self_pair
UNION ALL SELECT 'wrong_order',                  COUNT(*) FROM wrong_order
UNION ALL SELECT 'duplicate_pair_id',            COUNT(*) FROM duplicate_pair_id
UNION ALL SELECT 'pair_with_unmatchable_record', COUNT(*) FROM pair_with_unmatchable_record
UNION ALL SELECT 'pair_without_block',           COUNT(*) FROM pair_without_block
UNION ALL SELECT 'keys_not_in_staging',          COUNT(*) FROM keys_not_in_staging
UNION ALL SELECT 'oversized_block_used',         COUNT(*) FROM oversized_block_used
UNION ALL SELECT 'nzbn_pairs_are_linked',        COUNT(*) FROM nzbn_pairs_are_linked;
