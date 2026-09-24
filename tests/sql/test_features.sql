-- =============================================================================
-- test_features.sql
-- Purpose : Data tests for sql/05_features.sql.
--           Every test returns FAILURE rows: 0 rows = PASS.
--           The last query runs all tests at once and returns
--           test_name + failure_count (all 0 = everything passes).
-- Owner   : Data Analyst (Esha)
-- Inputs  : CURATED.MATCH_FEATURE, CURATED.CANDIDATE_PAIR,
--           STAGING.ORGANISATION_STD
-- Outputs : None (read-only queries).
-- =============================================================================

USE DATABASE KENDRIX;

-- Test: one_row_per_pair -- every candidate pair has exactly one feature row.
-- Fails on duplicate PAIR_IDs, pairs with no feature row, feature rows with no
-- pair, or a total count mismatch.
SELECT 'duplicate' AS problem, PAIR_ID
FROM CURATED.MATCH_FEATURE
GROUP BY PAIR_ID
HAVING COUNT(*) > 1
UNION ALL
SELECT 'pair_without_features', p.PAIR_ID
FROM CURATED.CANDIDATE_PAIR p
LEFT JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = p.PAIR_ID
WHERE f.PAIR_ID IS NULL
UNION ALL
SELECT 'features_without_pair', f.PAIR_ID
FROM CURATED.MATCH_FEATURE f
LEFT JOIN CURATED.CANDIDATE_PAIR p ON p.PAIR_ID = f.PAIR_ID
WHERE p.PAIR_ID IS NULL
UNION ALL
SELECT 'count_mismatch', NULL
WHERE (SELECT COUNT(*) FROM CURATED.MATCH_FEATURE)
   <> (SELECT COUNT(*) FROM CURATED.CANDIDATE_PAIR);

-- Test: jw_out_of_range -- Jaro-Winkler similarity is always 0-100.
SELECT PAIR_ID, NAME_JW, NAME_CORE_JW, ALT_NAME_JW, ADDRESS_JW
FROM CURATED.MATCH_FEATURE
WHERE NAME_JW      NOT BETWEEN 0 AND 100
   OR NAME_CORE_JW NOT BETWEEN 0 AND 100
   OR ALT_NAME_JW  NOT BETWEEN 0 AND 100
   OR ADDRESS_JW   NOT BETWEEN 0 AND 100;

-- Test: jw_rev_out_of_range -- the reversed-name Jaro-Winkler is also 0-100
-- (NULL is allowed: a side has no NAME_CORE).
SELECT PAIR_ID, NAME_CORE_JW_REV
FROM CURATED.MATCH_FEATURE
WHERE NAME_CORE_JW_REV NOT BETWEEN 0 AND 100;

-- Test: jaccard_out_of_range -- word overlap is a share, so always 0-1
-- (NULL is allowed: a side has no name words).
SELECT PAIR_ID, NAME_TOKEN_JACCARD
FROM CURATED.MATCH_FEATURE
WHERE NAME_TOKEN_JACCARD NOT BETWEEN 0 AND 1;

-- Test: eq_true_but_values_differ -- spot-check: PHONE_EQ = TRUE must mean the
-- two cleaned phone numbers really are identical.
SELECT f.PAIR_ID, l.PHONE_CLEAN AS LEFT_PHONE, r.PHONE_CLEAN AS RIGHT_PHONE
FROM CURATED.MATCH_FEATURE f
JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = f.PAIR_ID
JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
WHERE f.PHONE_EQ
  AND l.PHONE_CLEAN <> r.PHONE_CLEAN;

-- Test: eq_not_null_when_missing -- when either side has no phone, PHONE_EQ
-- must be NULL ("no evidence"), never FALSE.
SELECT f.PAIR_ID, f.PHONE_EQ, l.PHONE_CLEAN AS LEFT_PHONE, r.PHONE_CLEAN AS RIGHT_PHONE
FROM CURATED.MATCH_FEATURE f
JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = f.PAIR_ID
JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
WHERE (l.PHONE_CLEAN IS NULL OR r.PHONE_CLEAN IS NULL)
  AND f.PHONE_EQ IS NOT NULL;

-- Test: generic_email_used -- an email on a generic (free-mail/trustee) domain
-- is not evidence, so EMAIL_EQ must be NULL when either side is generic.
SELECT f.PAIR_ID, f.EMAIL_EQ, l.EMAIL_CLEAN AS LEFT_EMAIL, r.EMAIL_CLEAN AS RIGHT_EMAIL
FROM CURATED.MATCH_FEATURE f
JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = f.PAIR_ID
JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
WHERE (l.IS_GENERIC_EMAIL_DOMAIN OR r.IS_GENERIC_EMAIL_DOMAIN)
  AND f.EMAIL_EQ IS NOT NULL;

-- -----------------------------------------------------------------------------
-- All tests in one go: one CTE per test (same logic as above), then
-- test_name + failure_count. Every failure_count should be 0.
-- -----------------------------------------------------------------------------
WITH
pair_sides AS (
    SELECT f.PAIR_ID, f.PHONE_EQ, f.EMAIL_EQ,
           l.PHONE_CLEAN AS L_PHONE, r.PHONE_CLEAN AS R_PHONE,
           l.IS_GENERIC_EMAIL_DOMAIN AS L_GENERIC, r.IS_GENERIC_EMAIL_DOMAIN AS R_GENERIC
    FROM CURATED.MATCH_FEATURE f
    JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = f.PAIR_ID
    JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
    JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
),
one_row_per_pair AS (
    SELECT PAIR_ID FROM CURATED.MATCH_FEATURE
    GROUP BY PAIR_ID
    HAVING COUNT(*) > 1
    UNION ALL
    SELECT p.PAIR_ID
    FROM CURATED.CANDIDATE_PAIR p
    LEFT JOIN CURATED.MATCH_FEATURE f ON f.PAIR_ID = p.PAIR_ID
    WHERE f.PAIR_ID IS NULL
    UNION ALL
    SELECT f.PAIR_ID
    FROM CURATED.MATCH_FEATURE f
    LEFT JOIN CURATED.CANDIDATE_PAIR p ON p.PAIR_ID = f.PAIR_ID
    WHERE p.PAIR_ID IS NULL
    UNION ALL
    SELECT NULL
    WHERE (SELECT COUNT(*) FROM CURATED.MATCH_FEATURE)
       <> (SELECT COUNT(*) FROM CURATED.CANDIDATE_PAIR)
),
jw_out_of_range AS (
    SELECT PAIR_ID FROM CURATED.MATCH_FEATURE
    WHERE NAME_JW      NOT BETWEEN 0 AND 100
       OR NAME_CORE_JW NOT BETWEEN 0 AND 100
       OR ALT_NAME_JW  NOT BETWEEN 0 AND 100
       OR ADDRESS_JW   NOT BETWEEN 0 AND 100
),
jw_rev_out_of_range AS (
    SELECT PAIR_ID FROM CURATED.MATCH_FEATURE
    WHERE NAME_CORE_JW_REV NOT BETWEEN 0 AND 100
),
jaccard_out_of_range AS (
    SELECT PAIR_ID FROM CURATED.MATCH_FEATURE
    WHERE NAME_TOKEN_JACCARD NOT BETWEEN 0 AND 1
),
eq_true_but_values_differ AS (
    SELECT PAIR_ID FROM pair_sides
    WHERE PHONE_EQ AND L_PHONE <> R_PHONE
),
eq_not_null_when_missing AS (
    SELECT PAIR_ID FROM pair_sides
    WHERE (L_PHONE IS NULL OR R_PHONE IS NULL) AND PHONE_EQ IS NOT NULL
),
generic_email_used AS (
    SELECT PAIR_ID FROM pair_sides
    WHERE (L_GENERIC OR R_GENERIC) AND EMAIL_EQ IS NOT NULL
)
SELECT 'one_row_per_pair'           AS test_name, COUNT(*) AS failure_count FROM one_row_per_pair
UNION ALL SELECT 'jw_out_of_range',            COUNT(*) FROM jw_out_of_range
UNION ALL SELECT 'jw_rev_out_of_range',        COUNT(*) FROM jw_rev_out_of_range
UNION ALL SELECT 'jaccard_out_of_range',       COUNT(*) FROM jaccard_out_of_range
UNION ALL SELECT 'eq_true_but_values_differ',  COUNT(*) FROM eq_true_but_values_differ
UNION ALL SELECT 'eq_not_null_when_missing',   COUNT(*) FROM eq_not_null_when_missing
UNION ALL SELECT 'generic_email_used',         COUNT(*) FROM generic_email_used;
