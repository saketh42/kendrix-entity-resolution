-- =============================================================================
-- 05_features.sql
-- Purpose : Feature engineering. For every candidate pair from step 04, compare
--           the two records field by field (name similarity, address, contacts,
--           IDs) and write one row of features to CURATED.MATCH_FEATURE, which
--           step 06 turns into a score and a decision.
-- Owner   : Data Analyst (Esha)
-- Inputs  : CURATED.CANDIDATE_PAIR   (223,958 pairs, built by sql/04)
--           STAGING.ORGANISATION_STD (built by sql/03)
-- Outputs : CURATED.MATCH_FEATURE    - one row per candidate pair
--           one row in AUDIT.PIPELINE_RUN (step '05_features')
-- Notes   : Idempotent: new columns use ADD COLUMN IF NOT EXISTS, and the table
--           is truncated and fully rebuilt on every run. Rule version 'feat_v1'.
--           NULL in any *_EQ column means "no evidence" (a side is missing the
--           value), NOT "different". Step 06 must treat NULL and FALSE differently.
--           Tests: tests/sql/test_features.sql.
-- =============================================================================

USE DATABASE KENDRIX;

-- One RUN_ID for this run, shared by every row and the audit log entry.
-- SET only accepts constants or subqueries, so function calls are wrapped in (SELECT ...).
SET RUN_ID = (SELECT UUID_STRING());
SET STARTED_AT = (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

-- -----------------------------------------------------------------------------
-- 1) New columns on the contract table from sql/04.
--    Profiling found real emails/phones/websites shared by MANY unrelated
--    charities (one admin email on 286 records). Equality on such a value is
--    weak evidence, so each equality also records how widely the value is shared.
--    One ALTER per column: IF NOT EXISTS then applies to each column separately.
-- -----------------------------------------------------------------------------
ALTER TABLE CURATED.MATCH_FEATURE ADD COLUMN IF NOT EXISTS EMAIL_SHARED_COUNT NUMBER
    COMMENT 'How many ORGANISATION_STD records have this email (only when EMAIL_EQ); 2 = only this pair, high = shared admin/accountant';
ALTER TABLE CURATED.MATCH_FEATURE ADD COLUMN IF NOT EXISTS PHONE_SHARED_COUNT NUMBER
    COMMENT 'How many ORGANISATION_STD records have this phone (only when PHONE_EQ); 2 = only this pair, high = shared admin/accountant';
ALTER TABLE CURATED.MATCH_FEATURE ADD COLUMN IF NOT EXISTS WEBSITE_SHARED_COUNT NUMBER
    COMMENT 'How many ORGANISATION_STD records have this website domain (only when WEBSITE_EQ); 2 = only this pair, high = shared host/umbrella site';
ALTER TABLE CURATED.MATCH_FEATURE ADD COLUMN IF NOT EXISTS SAME_PARENT_CHARITY BOOLEAN
    COMMENT 'Same parent charity registration number but different registration numbers: related group members, NOT the same entity';
ALTER TABLE CURATED.MATCH_FEATURE ADD COLUMN IF NOT EXISTS COMPUTED_AT TIMESTAMP_NTZ
    COMMENT 'When this feature row was computed';
-- Jaro-Winkler gives a bonus for a shared start, so 'ESTATE OF ANDREW BLACK'
-- vs 'ESTATE OF KENNETH NORTH' scores high on the prefix alone. Comparing the
-- REVERSED names makes the (different) endings the prefix, which cancels that bonus.
ALTER TABLE CURATED.MATCH_FEATURE ADD COLUMN IF NOT EXISTS NAME_CORE_JW_REV NUMBER(5,2)
    COMMENT 'Jaro-Winkler of the REVERSED NAME_CORE values, 0-100; counters the prefix bias (ESTATE OF X vs ESTATE OF Y)';
-- A trustee company or accountant's office is the registered address of many
-- unrelated charities, so a shared address can be as weak as a shared admin email.
ALTER TABLE CURATED.MATCH_FEATURE ADD COLUMN IF NOT EXISTS ADDRESS_SHARED_COUNT NUMBER
    COMMENT 'Records with the same ADDRESS_LINE_CLEAN + POSTCODE, the larger of the two sides; NULL unless both sides have both';
-- Share of distinct words the two names have in common. Catches names that
-- share start AND end but differ in the key word (place, hapu, activity):
-- 'NGATI TU HAPU' vs 'NGATI HAUA HAPU' = 2 shared of 4 distinct words = 0.5.
ALTER TABLE CURATED.MATCH_FEATURE ADD COLUMN IF NOT EXISTS NAME_TOKEN_JACCARD NUMBER(5,2)
    COMMENT 'Best word-overlap (Jaccard, 0-1) over all core names/alt names of the two sides: shared distinct words / all distinct words';

-- -----------------------------------------------------------------------------
-- 2) Rebuild the features: one row per candidate pair.
-- -----------------------------------------------------------------------------
TRUNCATE TABLE CURATED.MATCH_FEATURE;

INSERT INTO CURATED.MATCH_FEATURE (
    PAIR_ID, NAME_JW, NAME_CORE_JW, ALT_NAME_JW, ADDRESS_JW,
    POSTCODE_EQ, CITY_EQ, PHONE_EQ, EMAIL_EQ, WEBSITE_EQ, NZBN_EQ, COMPANY_NO_EQ,
    EMAIL_SHARED_COUNT, PHONE_SHARED_COUNT, WEBSITE_SHARED_COUNT,
    SAME_PARENT_CHARITY, RUN_ID, COMPUTED_AT,
    NAME_CORE_JW_REV, ADDRESS_SHARED_COUNT, NAME_TOKEN_JACCARD
)
WITH
-- Both records of every pair side by side (L_ = left record, R_ = right record).
pairs AS (
    SELECT
        p.PAIR_ID, p.LEFT_KEY, p.RIGHT_KEY,
        l.NAME_CLEAN              AS L_NAME,     r.NAME_CLEAN              AS R_NAME,
        l.NAME_CORE               AS L_CORE,     r.NAME_CORE               AS R_CORE,
        l.ALT_NAMES               AS L_ALT,      r.ALT_NAMES               AS R_ALT,
        l.ADDRESS_LINE_CLEAN      AS L_ADDR,     r.ADDRESS_LINE_CLEAN      AS R_ADDR,
        l.POSTCODE                AS L_PC,       r.POSTCODE                AS R_PC,
        l.CITY                    AS L_CITY,     r.CITY                    AS R_CITY,
        l.PHONE_CLEAN             AS L_PHONE,    r.PHONE_CLEAN             AS R_PHONE,
        l.EMAIL_CLEAN             AS L_EMAIL,    r.EMAIL_CLEAN             AS R_EMAIL,
        l.IS_GENERIC_EMAIL_DOMAIN AS L_GENERIC,  r.IS_GENERIC_EMAIL_DOMAIN AS R_GENERIC,
        l.WEBSITE_DOMAIN          AS L_WEB,      r.WEBSITE_DOMAIN          AS R_WEB,
        l.NZBN                    AS L_NZBN,     r.NZBN                    AS R_NZBN,
        l.COMPANY_NO              AS L_CO,       r.COMPANY_NO              AS R_CO,
        l.CHARITY_REG_NO          AS L_REG,      r.CHARITY_REG_NO          AS R_REG,
        l.CHARITY_PARENT_REG_NO   AS L_PARENT,   r.CHARITY_PARENT_REG_NO   AS R_PARENT
    FROM CURATED.CANDIDATE_PAIR p
    JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
    JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
),

-- How many records carry each value, counted over ALL of ORGANISATION_STD
-- (not just candidate pairs), because the question is "how common is this
-- value in the register", e.g. one accountant's email on 286 charities.
email_counts AS (
    SELECT EMAIL_CLEAN AS VAL, COUNT(*) AS N
    FROM STAGING.ORGANISATION_STD
    WHERE EMAIL_CLEAN IS NOT NULL
    GROUP BY EMAIL_CLEAN
),
phone_counts AS (
    SELECT PHONE_CLEAN AS VAL, COUNT(*) AS N
    FROM STAGING.ORGANISATION_STD
    WHERE PHONE_CLEAN IS NOT NULL
    GROUP BY PHONE_CLEAN
),
website_counts AS (
    SELECT WEBSITE_DOMAIN AS VAL, COUNT(*) AS N
    FROM STAGING.ORGANISATION_STD
    WHERE WEBSITE_DOMAIN IS NOT NULL
    GROUP BY WEBSITE_DOMAIN
),
-- Address + postcode together, so '1 MAIN ST' in two different towns is not
-- counted as one address. '|' keeps the two parts from running together.
address_counts AS (
    SELECT ADDRESS_LINE_CLEAN || '|' || POSTCODE AS VAL, COUNT(*) AS N
    FROM STAGING.ORGANISATION_STD
    WHERE ADDRESS_LINE_CLEAN IS NOT NULL AND POSTCODE IS NOT NULL
    GROUP BY 1
),

-- Pairs where at least one side has alternative names (other/trading/former).
-- ALT_NAMES is [] (not NULL) when there are none, hence ARRAY_SIZE. Pairs with
-- no alt names on either side get ALT_NAME_JW = NULL: no extra name evidence,
-- and NAME_JW already covers main name vs main name.
pairs_with_alt AS (
    SELECT PAIR_ID, LEFT_KEY, RIGHT_KEY
    FROM pairs
    WHERE ARRAY_SIZE(COALESCE(L_ALT, ARRAY_CONSTRUCT())) > 0
       OR ARRAY_SIZE(COALESCE(R_ALT, ARRAY_CONSTRUCT())) > 0
),

-- Every name of each record involved: NAME_CLEAN plus each ALT_NAMES value.
-- OUTER => TRUE keeps a record even if its name list is somehow empty, so it
-- never silently drops out of the pair.
record_names AS (
    SELECT s.RECORD_KEY, f.VALUE::VARCHAR AS NM
    FROM STAGING.ORGANISATION_STD s,
         LATERAL FLATTEN(INPUT => ARRAY_CAT(ARRAY_CONSTRUCT_COMPACT(s.NAME_CLEAN),
                                            COALESCE(s.ALT_NAMES, ARRAY_CONSTRUCT())),
                         OUTER => TRUE) f
    WHERE s.RECORD_KEY IN (SELECT LEFT_KEY FROM pairs_with_alt
                           UNION
                           SELECT RIGHT_KEY FROM pairs_with_alt)
),

-- Best similarity between ANY name of the left record and ANY name of the right
-- record, so a former name can match the other record's current name.
-- The cross product is small: most records have 1 to 3 names.
-- Each combination takes the LOWER of forward and reversed Jaro-Winkler (same
-- prefix-bias protection as NAME_CORE_JW_REV), so a shared start alone cannot
-- make two names look alike through the alt-name path either.
alt_name_best AS (
    SELECT pa.PAIR_ID,
           MAX(LEAST(JAROWINKLER_SIMILARITY(ln.NM, rn.NM),
                     JAROWINKLER_SIMILARITY(REVERSE(ln.NM), REVERSE(rn.NM)))) AS ALT_NAME_JW
    FROM pairs_with_alt pa
    JOIN record_names ln ON ln.RECORD_KEY = pa.LEFT_KEY
    JOIN record_names rn ON rn.RECORD_KEY = pa.RIGHT_KEY
    GROUP BY pa.PAIR_ID
),

-- Word sets of every core name of every record in a pair: NAME_CORE (or
-- NAME_CLEAN if the core is empty) plus the core of each alt name (same
-- FN_NAME_CORE rule as sql/04), so legal-form words like 'TRUST' or
-- 'INCORPORATED' do not count as shared words. ARRAY_DISTINCT once here, so
-- each word counts once.
record_word_sets AS (
    SELECT s.RECORD_KEY, ARRAY_DISTINCT(SPLIT(COALESCE(s.NAME_CORE, s.NAME_CLEAN), ' ')) AS WORDS
    FROM STAGING.ORGANISATION_STD s
    WHERE COALESCE(s.NAME_CORE, s.NAME_CLEAN) IS NOT NULL
      AND s.RECORD_KEY IN (SELECT LEFT_KEY FROM pairs UNION SELECT RIGHT_KEY FROM pairs)
    UNION ALL
    SELECT s.RECORD_KEY, ARRAY_DISTINCT(SPLIT(STAGING.FN_NAME_CORE(f.VALUE::VARCHAR), ' '))
    FROM STAGING.ORGANISATION_STD s,
         LATERAL FLATTEN(INPUT => s.ALT_NAMES) f
    WHERE f.VALUE IS NOT NULL
      AND STAGING.FN_NAME_CORE(f.VALUE::VARCHAR) IS NOT NULL
      AND s.RECORD_KEY IN (SELECT LEFT_KEY FROM pairs UNION SELECT RIGHT_KEY FROM pairs)
),

-- Jaccard = shared distinct words / all distinct words of the two names, 0-1.
-- Best over every name combination, like ALT_NAME_JW.
name_jaccard AS (
    SELECT p.PAIR_ID,
           MAX(ARRAY_SIZE(ARRAY_INTERSECTION(lw.WORDS, rw.WORDS))
               / NULLIF(ARRAY_SIZE(ARRAY_DISTINCT(ARRAY_CAT(lw.WORDS, rw.WORDS))), 0)) AS NAME_TOKEN_JACCARD
    FROM pairs p
    JOIN record_word_sets lw ON lw.RECORD_KEY = p.LEFT_KEY
    JOIN record_word_sets rw ON rw.RECORD_KEY = p.RIGHT_KEY
    GROUP BY p.PAIR_ID
),

features AS (
    SELECT
        p.PAIR_ID,
        p.L_EMAIL, p.L_PHONE, p.L_WEB,
        -- NULL unless the side has both parts (then no address count is joined).
        p.L_ADDR || '|' || p.L_PC                   AS L_ADDR_KEY,
        p.R_ADDR || '|' || p.R_PC                   AS R_ADDR_KEY,
        JAROWINKLER_SIMILARITY(REVERSE(p.L_CORE), REVERSE(p.R_CORE)) AS NAME_CORE_JW_REV,
        -- JAROWINKLER_SIMILARITY returns 0-100 and NULL if either input is NULL,
        -- so a missing address gives ADDRESS_JW = NULL (no evidence), not 0.
        JAROWINKLER_SIMILARITY(p.L_NAME, p.R_NAME)  AS NAME_JW,
        -- NAME_CORE has 'THE' and legal-form words removed, so 'X Trust' and
        -- 'X Charitable Trust' score high here even when NAME_JW is lower.
        JAROWINKLER_SIMILARITY(p.L_CORE, p.R_CORE)  AS NAME_CORE_JW,
        a.ALT_NAME_JW,
        ROUND(j.NAME_TOKEN_JACCARD, 2)              AS NAME_TOKEN_JACCARD,
        JAROWINKLER_SIMILARITY(p.L_ADDR, p.R_ADDR)  AS ADDRESS_JW,
        -- Plain '=' on purpose: SQL equality already returns NULL when either
        -- side is NULL, which is exactly "no evidence". Do NOT wrap these in
        -- COALESCE(..., FALSE): missing is not the same as different.
        (p.L_PC   = p.R_PC)                         AS POSTCODE_EQ,
        (p.L_CITY = p.R_CITY)                       AS CITY_EQ,
        (p.L_PHONE = p.R_PHONE)                     AS PHONE_EQ,
        -- Free-mail and trustee-company domains are shared by unrelated
        -- charities (same rule as the EMAIL block in sql/04), so an email on
        -- such a domain gives no evidence either way.
        CASE
            WHEN p.L_GENERIC OR p.R_GENERIC THEN NULL
            ELSE (p.L_EMAIL = p.R_EMAIL)
        END                                         AS EMAIL_EQ,
        (p.L_WEB  = p.R_WEB)                        AS WEBSITE_EQ,
        -- NZBN_EQ = FALSE is important: two DIFFERENT real identifiers is strong
        -- evidence AGAINST a match (conflicting IDs), not just missing evidence.
        (p.L_NZBN = p.R_NZBN)                       AS NZBN_EQ,
        -- Only charities carry a Companies Office number, so this is non-NULL
        -- on charity-charity pairs only.
        (p.L_CO   = p.R_CO)                         AS COMPANY_NO_EQ,
        -- Group members are numbered CC<parent>-<n>. Same parent but different
        -- registration numbers = related organisations in one group, which must
        -- NOT be merged as one entity. NULL when either side has no reg number
        -- (every Companies Office record).
        (p.L_PARENT = p.R_PARENT AND p.L_REG <> p.R_REG) AS SAME_PARENT_CHARITY
    FROM pairs p
    LEFT JOIN alt_name_best a ON a.PAIR_ID = p.PAIR_ID
    LEFT JOIN name_jaccard  j ON j.PAIR_ID = p.PAIR_ID
)

-- Shared counts are only filled when the pair is EQUAL on that value (the EQ
-- condition sits in the join), otherwise NULL: the count describes the value
-- the two records share, so it means nothing when they do not share one.
SELECT
    f.PAIR_ID,
    f.NAME_JW, f.NAME_CORE_JW, f.ALT_NAME_JW, f.ADDRESS_JW,
    f.POSTCODE_EQ, f.CITY_EQ, f.PHONE_EQ, f.EMAIL_EQ, f.WEBSITE_EQ, f.NZBN_EQ, f.COMPANY_NO_EQ,
    ec.N                                            AS EMAIL_SHARED_COUNT,
    pc.N                                            AS PHONE_SHARED_COUNT,
    wc.N                                            AS WEBSITE_SHARED_COUNT,
    f.SAME_PARENT_CHARITY,
    $RUN_ID::VARCHAR                                AS RUN_ID,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ              AS COMPUTED_AT,
    f.NAME_CORE_JW_REV,
    -- Unlike the contact counts this is filled whether or not the addresses
    -- are equal (ADDRESS_JW is a similarity, not an equality). The LARGER side
    -- is used: if either record sits at a busy trustee address, comparing
    -- addresses says little about identity.
    IFF(la.N IS NOT NULL AND ra.N IS NOT NULL, GREATEST(la.N, ra.N), NULL)
                                                    AS ADDRESS_SHARED_COUNT,
    f.NAME_TOKEN_JACCARD
FROM features f
LEFT JOIN email_counts   ec ON ec.VAL = f.L_EMAIL AND f.EMAIL_EQ
LEFT JOIN phone_counts   pc ON pc.VAL = f.L_PHONE AND f.PHONE_EQ
LEFT JOIN website_counts wc ON wc.VAL = f.L_WEB   AND f.WEBSITE_EQ
LEFT JOIN address_counts la ON la.VAL = f.L_ADDR_KEY
LEFT JOIN address_counts ra ON ra.VAL = f.R_ADDR_KEY;

-- -----------------------------------------------------------------------------
-- 3) Audit log row. SUCCESS only if every candidate pair got exactly one
--    feature row (and there were pairs at all).
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.PIPELINE_RUN (RUN_ID, STEP, STARTED_AT, FINISHED_AT, ROWS_OUT, RULE_VERSION, STATUS, NOTES)
SELECT $RUN_ID, '05_features',
       $STARTED_AT,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
       f.n, 'feat_v1',
       IFF(f.n = p.n AND f.n > 0, 'SUCCESS', 'FAIL'),
       'pairs=' || p.n
FROM (SELECT COUNT(*) n FROM CURATED.MATCH_FEATURE) f,
     (SELECT COUNT(*) n FROM CURATED.CANDIDATE_PAIR) p;

-- -----------------------------------------------------------------------------
-- 4) Summary (last, so this result is what you see in Snowsight).
--    One (METRIC, VALUE) table. pct_null_* = share of pairs with NO evidence
--    for that field (either side missing), which shows how much each feature
--    can contribute to scoring.
-- -----------------------------------------------------------------------------
SELECT METRIC, VALUE
FROM (
    SELECT 1 AS SORT_ORDER, 'feature_rows' AS METRIC, COUNT(*)::NUMBER(18,2) AS VALUE
    FROM CURATED.MATCH_FEATURE
    UNION ALL
    SELECT 2, 'candidate_pairs', COUNT(*)
    FROM CURATED.CANDIDATE_PAIR
    UNION ALL
    SELECT 3, 'avg_name_core_jw', ROUND(AVG(NAME_CORE_JW), 2)
    FROM CURATED.MATCH_FEATURE
    UNION ALL
    -- UNPIVOT turns the 7 columns into 7 rows; it returns column names in
    -- upper case, so LOWER keeps the metric names consistent with the rest.
    SELECT 4, LOWER(m.METRIC), m.VALUE
    FROM (
        SELECT
            ROUND(100 * COUNT_IF(POSTCODE_EQ   IS NULL) / NULLIF(COUNT(*), 0), 2) AS pct_null_postcode_eq,
            ROUND(100 * COUNT_IF(CITY_EQ       IS NULL) / NULLIF(COUNT(*), 0), 2) AS pct_null_city_eq,
            ROUND(100 * COUNT_IF(PHONE_EQ      IS NULL) / NULLIF(COUNT(*), 0), 2) AS pct_null_phone_eq,
            ROUND(100 * COUNT_IF(EMAIL_EQ      IS NULL) / NULLIF(COUNT(*), 0), 2) AS pct_null_email_eq,
            ROUND(100 * COUNT_IF(WEBSITE_EQ    IS NULL) / NULLIF(COUNT(*), 0), 2) AS pct_null_website_eq,
            ROUND(100 * COUNT_IF(NZBN_EQ       IS NULL) / NULLIF(COUNT(*), 0), 2) AS pct_null_nzbn_eq,
            ROUND(100 * COUNT_IF(COMPANY_NO_EQ IS NULL) / NULLIF(COUNT(*), 0), 2) AS pct_null_company_no_eq
        FROM CURATED.MATCH_FEATURE
    ) UNPIVOT (VALUE FOR METRIC IN (
        pct_null_postcode_eq, pct_null_city_eq, pct_null_phone_eq, pct_null_email_eq,
        pct_null_website_eq, pct_null_nzbn_eq, pct_null_company_no_eq)) m
    UNION ALL
    SELECT 5, 'phone_eq_true', COUNT_IF(PHONE_EQ)
    FROM CURATED.MATCH_FEATURE
    UNION ALL
    SELECT 6, 'email_eq_true', COUNT_IF(EMAIL_EQ)
    FROM CURATED.MATCH_FEATURE
    UNION ALL
    SELECT 7, 'nzbn_eq_true', COUNT_IF(NZBN_EQ)
    FROM CURATED.MATCH_FEATURE
    UNION ALL
    -- Both sides have an NZBN and they differ: conflicting IDs, candidates for
    -- the exception queue rather than a match.
    SELECT 8, 'nzbn_eq_false_conflicting_ids', COUNT_IF(NOT NZBN_EQ)
    FROM CURATED.MATCH_FEATURE
    UNION ALL
    -- Equal emails that are shared by more than 10 records: shared admin or
    -- accountant addresses, which step 06 should down-weight.
    SELECT 9, 'email_eq_true_shared_gt_10', COUNT_IF(EMAIL_EQ AND EMAIL_SHARED_COUNT > 10)
    FROM CURATED.MATCH_FEATURE
)
ORDER BY SORT_ORDER, METRIC;
