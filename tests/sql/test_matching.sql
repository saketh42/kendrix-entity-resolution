-- =============================================================================
-- test_matching.sql
-- Purpose : Data tests for sql/06_matching.sql.
--           Every test returns FAILURE rows: 0 rows = PASS.
--           The last query runs all tests at once and returns
--           test_name + failure_count (all 0 = everything passes).
--           Thresholds (85) are written out here on purpose, so the tests
--           check the agreed rules rather than whatever 06 currently uses.
-- Owner   : Data Analyst (Esha)
-- Inputs  : CURATED.MATCH_DECISION, CURATED.MATCH_FEATURE,
--           AUDIT.MATCH_EVIDENCE, AUDIT.EXCEPTION_QUEUE,
--           CURATED.CANDIDATE_PAIR, STAGING.ORGANISATION_STD
-- Outputs : None (read-only queries).
-- =============================================================================

USE DATABASE KENDRIX;

-- Test: one_decision_per_pair -- every feature row has exactly one decision.
-- Fails on duplicate PAIR_IDs, pairs with no decision, decisions with no
-- feature row, or a total count mismatch.
SELECT 'duplicate' AS problem, PAIR_ID
FROM CURATED.MATCH_DECISION
GROUP BY PAIR_ID
HAVING COUNT(*) > 1
UNION ALL
SELECT 'pair_without_decision', f.PAIR_ID
FROM CURATED.MATCH_FEATURE f
LEFT JOIN CURATED.MATCH_DECISION d ON d.PAIR_ID = f.PAIR_ID
WHERE d.PAIR_ID IS NULL
UNION ALL
SELECT 'decision_without_pair', d.PAIR_ID
FROM CURATED.MATCH_DECISION d
LEFT JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
WHERE f.PAIR_ID IS NULL
UNION ALL
SELECT 'count_mismatch', NULL
WHERE (SELECT COUNT(*) FROM CURATED.MATCH_DECISION)
   <> (SELECT COUNT(*) FROM CURATED.MATCH_FEATURE);

-- Test: score_out_of_range -- SCORE and FUZZY_SCORE are always present and 0-100.
SELECT PAIR_ID, SCORE, FUZZY_SCORE
FROM CURATED.MATCH_DECISION
WHERE SCORE IS NULL OR FUZZY_SCORE IS NULL
   OR SCORE       NOT BETWEEN 0 AND 100
   OR FUZZY_SCORE NOT BETWEEN 0 AND 100;

-- Test: invalid_decision_value -- decisions and paths only take known values.
SELECT PAIR_ID, DECISION, FUZZY_DECISION, DECISION_PATH
FROM CURATED.MATCH_DECISION
WHERE DECISION       IS NULL OR DECISION       NOT IN ('AUTO_MATCH', 'REVIEW', 'NO_MATCH')
   OR FUZZY_DECISION IS NULL OR FUZZY_DECISION NOT IN ('AUTO_MATCH', 'REVIEW', 'NO_MATCH')
   OR DECISION_PATH  IS NULL OR DECISION_PATH  NOT IN ('ID_MATCH', 'ID_MATCH_NAME_DIFFERS', 'ID_CONFLICT',
                                                       'ID_CONFLICT_REVIEW', 'RELATED_GROUP_MEMBER', 'FUZZY');

-- Test: auto_match_on_id_conflict -- two different NZBNs must never be merged
-- automatically in production.
SELECT d.PAIR_ID, d.DECISION, d.DECISION_PATH
FROM CURATED.MATCH_DECISION d
JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
WHERE d.DECISION = 'AUTO_MATCH'
  AND f.NZBN_EQ = FALSE;

-- Test: fuzzy_auto_without_second_evidence -- a fuzzy AUTO_MATCH needs score
-- >= 85, name >= 85, and at least one agreeing non-name feature in the ledger
-- that kept weight > 0 (address >= 85, same postcode, or a same
-- phone/email/website). Weight 0 = heavily shared (a trustee address or an
-- admin email). Checked against AUDIT.MATCH_EVIDENCE, not 06's own flags.
SELECT d.PAIR_ID, d.FUZZY_SCORE
FROM CURATED.MATCH_DECISION d
WHERE d.FUZZY_DECISION = 'AUTO_MATCH'
  AND (d.FUZZY_SCORE < 85
       OR NOT EXISTS (
           SELECT 1 FROM AUDIT.MATCH_EVIDENCE e
           WHERE e.PAIR_ID = d.PAIR_ID
             AND e.FEATURE = 'NAME_BEST_JW' AND e.SIMILARITY >= 85)
       OR NOT EXISTS (
           SELECT 1 FROM AUDIT.MATCH_EVIDENCE e
           WHERE e.PAIR_ID = d.PAIR_ID
             AND e.WEIGHT > 0
             AND (   (e.FEATURE = 'ADDRESS_JW'  AND e.SIMILARITY >= 85)
                  OR (e.FEATURE = 'POSTCODE_EQ' AND e.SIMILARITY = 100)
                  OR (e.FEATURE IN ('PHONE_EQ', 'EMAIL_EQ', 'WEBSITE_EQ')
                      AND e.SIMILARITY = 100))));

-- Test: estate_prefix_false_match -- the v1 false matches: two deceased
-- estates ('Estate of Andrew Black' vs 'Estate of Kenneth Arnold North')
-- auto-matched on the shared 'ESTATE OF' prefix. A fuzzy AUTO_MATCH between two
-- estates must also agree on the END of the name (reversed Jaro-Winkler >= 85).
SELECT d.PAIR_ID, l.NAME_RAW AS LEFT_NAME, r.NAME_RAW AS RIGHT_NAME,
       f.NAME_CORE_JW_REV, d.SCORE
FROM CURATED.MATCH_DECISION d
JOIN CURATED.MATCH_FEATURE f    ON f.PAIR_ID    = d.PAIR_ID
JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = d.PAIR_ID
JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
WHERE d.DECISION_PATH = 'FUZZY'
  AND d.DECISION = 'AUTO_MATCH'
  AND l.NAME_RAW ILIKE 'Estate of%'
  AND r.NAME_RAW ILIKE 'Estate of%'
  AND f.NAME_CORE_JW_REV < 85;

-- Test: auto_low_token_overlap -- the v2 false matches shared start and end
-- but not the key word ('Ngati Tu Hapu' vs 'Ngati Haua Hapu'). A fuzzy
-- AUTO_MATCH must share at least 75% of its distinct name words. A NULL
-- overlap counts as 0, the same as the gate in 06.
SELECT d.PAIR_ID, f.NAME_TOKEN_JACCARD, d.SCORE
FROM CURATED.MATCH_DECISION d
JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
WHERE d.DECISION_PATH = 'FUZZY'
  AND d.DECISION = 'AUTO_MATCH'
  AND COALESCE(f.NAME_TOKEN_JACCARD, 0) < 0.75;

-- Test: id_match_low_overlap_auto -- the v3 branch merges: same NZBN but
-- differently named charities ('St John Kawhia Area Committee' vs 'St John
-- Murupara Area Committee'). An ID-based AUTO_MATCH must share at least 75%
-- of its distinct name words (the same threshold as the fuzzy AUTO_MATCH
-- gate); otherwise it belongs in REVIEW. A NULL overlap counts as 0 (v5: a
-- missing value fails the gate instead of skipping it).
SELECT d.PAIR_ID, d.DECISION_PATH, f.NAME_TOKEN_JACCARD
FROM CURATED.MATCH_DECISION d
JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
WHERE d.DECISION = 'AUTO_MATCH'
  AND d.DECISION_PATH IN ('ID_MATCH', 'ID_MATCH_NAME_DIFFERS', 'ID_CONFLICT', 'ID_CONFLICT_REVIEW')
  AND COALESCE(f.NAME_TOKEN_JACCARD, 0) < 0.75;

-- Test: auto_via_widely_shared_id -- the v4 St John merges: area committees
-- with no NZBN auto-merged through the parent's shared company number. An
-- ID-based AUTO_MATCH is only allowed when the ID that drove it (the NZBN, or
-- the company number when there is no NZBN evidence) is on at most 3 records.
SELECT d.PAIR_ID, d.DECISION_PATH, f.NZBN_SHARED_COUNT, f.COMPANY_NO_SHARED_COUNT
FROM CURATED.MATCH_DECISION d
JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
WHERE d.DECISION = 'AUTO_MATCH'
  AND d.DECISION_PATH IN ('ID_MATCH', 'ID_MATCH_NAME_DIFFERS', 'ID_CONFLICT', 'ID_CONFLICT_REVIEW')
  AND (   (f.NZBN_EQ = TRUE AND f.NZBN_SHARED_COUNT > 3)
       OR (f.NZBN_EQ IS NULL AND f.COMPANY_NO_EQ = TRUE AND f.COMPANY_NO_SHARED_COUNT > 3));

-- Test: review_not_in_queue -- every production REVIEW pair is in the queue.
SELECT d.PAIR_ID, d.DECISION_PATH, d.SCORE
FROM CURATED.MATCH_DECISION d
LEFT JOIN AUDIT.EXCEPTION_QUEUE q ON q.PAIR_ID = d.PAIR_ID
WHERE d.DECISION = 'REVIEW'
  AND q.PAIR_ID IS NULL;

-- Test: evidence_missing -- every AUTO_MATCH or REVIEW pair can be explained:
-- it has at least one row in the evidence ledger.
SELECT d.PAIR_ID, d.DECISION, d.DECISION_PATH
FROM CURATED.MATCH_DECISION d
LEFT JOIN AUDIT.MATCH_EVIDENCE e ON e.PAIR_ID = d.PAIR_ID
WHERE d.DECISION IN ('AUTO_MATCH', 'REVIEW')
  AND e.PAIR_ID IS NULL;

-- Test: weights_sum_check -- on the FUZZY path the ledger's contributions add
-- up to FUZZY_SCORE (0.5 tolerance for per-row rounding). Identifier rows have
-- CONTRIBUTION NULL, which SUM ignores.
SELECT d.PAIR_ID, d.FUZZY_SCORE, SUM(e.CONTRIBUTION) AS CONTRIBUTION_SUM
FROM CURATED.MATCH_DECISION d
LEFT JOIN AUDIT.MATCH_EVIDENCE e ON e.PAIR_ID = d.PAIR_ID
WHERE d.DECISION_PATH = 'FUZZY'
GROUP BY d.PAIR_ID, d.FUZZY_SCORE
HAVING ABS(COALESCE(SUM(e.CONTRIBUTION), 0) - d.FUZZY_SCORE) > 0.5;

-- -----------------------------------------------------------------------------
-- All tests in one go: one CTE per test (same logic as above), then
-- test_name + failure_count. Every failure_count should be 0.
-- -----------------------------------------------------------------------------
WITH
one_decision_per_pair AS (
    SELECT PAIR_ID FROM CURATED.MATCH_DECISION
    GROUP BY PAIR_ID
    HAVING COUNT(*) > 1
    UNION ALL
    SELECT f.PAIR_ID
    FROM CURATED.MATCH_FEATURE f
    LEFT JOIN CURATED.MATCH_DECISION d ON d.PAIR_ID = f.PAIR_ID
    WHERE d.PAIR_ID IS NULL
    UNION ALL
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    LEFT JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
    WHERE f.PAIR_ID IS NULL
    UNION ALL
    SELECT NULL
    WHERE (SELECT COUNT(*) FROM CURATED.MATCH_DECISION)
       <> (SELECT COUNT(*) FROM CURATED.MATCH_FEATURE)
),
score_out_of_range AS (
    SELECT PAIR_ID FROM CURATED.MATCH_DECISION
    WHERE SCORE IS NULL OR FUZZY_SCORE IS NULL
       OR SCORE       NOT BETWEEN 0 AND 100
       OR FUZZY_SCORE NOT BETWEEN 0 AND 100
),
invalid_decision_value AS (
    SELECT PAIR_ID FROM CURATED.MATCH_DECISION
    WHERE DECISION       IS NULL OR DECISION       NOT IN ('AUTO_MATCH', 'REVIEW', 'NO_MATCH')
       OR FUZZY_DECISION IS NULL OR FUZZY_DECISION NOT IN ('AUTO_MATCH', 'REVIEW', 'NO_MATCH')
       OR DECISION_PATH  IS NULL OR DECISION_PATH  NOT IN ('ID_MATCH', 'ID_MATCH_NAME_DIFFERS', 'ID_CONFLICT',
                                                           'ID_CONFLICT_REVIEW', 'RELATED_GROUP_MEMBER', 'FUZZY')
),
auto_match_on_id_conflict AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION = 'AUTO_MATCH'
      AND f.NZBN_EQ = FALSE
),
fuzzy_auto_without_second_evidence AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    WHERE d.FUZZY_DECISION = 'AUTO_MATCH'
      AND (d.FUZZY_SCORE < 85
           OR NOT EXISTS (
               SELECT 1 FROM AUDIT.MATCH_EVIDENCE e
               WHERE e.PAIR_ID = d.PAIR_ID
                 AND e.FEATURE = 'NAME_BEST_JW' AND e.SIMILARITY >= 85)
           OR NOT EXISTS (
               SELECT 1 FROM AUDIT.MATCH_EVIDENCE e
               WHERE e.PAIR_ID = d.PAIR_ID
                 AND e.WEIGHT > 0
                 AND (   (e.FEATURE = 'ADDRESS_JW'  AND e.SIMILARITY >= 85)
                      OR (e.FEATURE = 'POSTCODE_EQ' AND e.SIMILARITY = 100)
                      OR (e.FEATURE IN ('PHONE_EQ', 'EMAIL_EQ', 'WEBSITE_EQ')
                          AND e.SIMILARITY = 100))))
),
estate_prefix_false_match AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.MATCH_FEATURE f    ON f.PAIR_ID    = d.PAIR_ID
    JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = d.PAIR_ID
    JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
    JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
    WHERE d.DECISION_PATH = 'FUZZY'
      AND d.DECISION = 'AUTO_MATCH'
      AND l.NAME_RAW ILIKE 'Estate of%'
      AND r.NAME_RAW ILIKE 'Estate of%'
      AND f.NAME_CORE_JW_REV < 85
),
auto_low_token_overlap AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION_PATH = 'FUZZY'
      AND d.DECISION = 'AUTO_MATCH'
      AND COALESCE(f.NAME_TOKEN_JACCARD, 0) < 0.75
),
id_match_low_overlap_auto AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION = 'AUTO_MATCH'
      AND d.DECISION_PATH IN ('ID_MATCH', 'ID_MATCH_NAME_DIFFERS', 'ID_CONFLICT', 'ID_CONFLICT_REVIEW')
      AND COALESCE(f.NAME_TOKEN_JACCARD, 0) < 0.75
),
auto_via_widely_shared_id AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION = 'AUTO_MATCH'
      AND d.DECISION_PATH IN ('ID_MATCH', 'ID_MATCH_NAME_DIFFERS', 'ID_CONFLICT', 'ID_CONFLICT_REVIEW')
      AND (   (f.NZBN_EQ = TRUE AND f.NZBN_SHARED_COUNT > 3)
           OR (f.NZBN_EQ IS NULL AND f.COMPANY_NO_EQ = TRUE AND f.COMPANY_NO_SHARED_COUNT > 3))
),
review_not_in_queue AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    LEFT JOIN AUDIT.EXCEPTION_QUEUE q ON q.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION = 'REVIEW'
      AND q.PAIR_ID IS NULL
),
evidence_missing AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    LEFT JOIN AUDIT.MATCH_EVIDENCE e ON e.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION IN ('AUTO_MATCH', 'REVIEW')
      AND e.PAIR_ID IS NULL
),
weights_sum_check AS (
    SELECT d.PAIR_ID
    FROM CURATED.MATCH_DECISION d
    LEFT JOIN AUDIT.MATCH_EVIDENCE e ON e.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION_PATH = 'FUZZY'
    GROUP BY d.PAIR_ID, d.FUZZY_SCORE
    HAVING ABS(COALESCE(SUM(e.CONTRIBUTION), 0) - d.FUZZY_SCORE) > 0.5
)
SELECT 'one_decision_per_pair'                  AS test_name, COUNT(*) AS failure_count FROM one_decision_per_pair
UNION ALL SELECT 'score_out_of_range',                  COUNT(*) FROM score_out_of_range
UNION ALL SELECT 'invalid_decision_value',              COUNT(*) FROM invalid_decision_value
UNION ALL SELECT 'auto_match_on_id_conflict',           COUNT(*) FROM auto_match_on_id_conflict
UNION ALL SELECT 'fuzzy_auto_without_second_evidence',  COUNT(*) FROM fuzzy_auto_without_second_evidence
UNION ALL SELECT 'estate_prefix_false_match',           COUNT(*) FROM estate_prefix_false_match
UNION ALL SELECT 'auto_low_token_overlap',              COUNT(*) FROM auto_low_token_overlap
UNION ALL SELECT 'id_match_low_overlap_auto',           COUNT(*) FROM id_match_low_overlap_auto
UNION ALL SELECT 'auto_via_widely_shared_id',           COUNT(*) FROM auto_via_widely_shared_id
UNION ALL SELECT 'review_not_in_queue',                 COUNT(*) FROM review_not_in_queue
UNION ALL SELECT 'evidence_missing',                    COUNT(*) FROM evidence_missing
UNION ALL SELECT 'weights_sum_check',                   COUNT(*) FROM weights_sum_check;
