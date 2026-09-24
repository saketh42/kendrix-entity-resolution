-- =============================================================================
-- 04_candidates.sql
-- Purpose : Blocking. Comparing every record with every other record
--           (~47.7k x 47.7k) is far too expensive, so each record gets a few
--           blocking keys and only records that share a key become candidate
--           pairs. Also creates the empty "contract" tables that steps 05/06
--           fill, so both sides agree on column names and types up front.
-- Owner   : Data Engineer (Shubham)
-- Inputs  : STAGING.ORGANISATION_STD (47,709 rows), STAGING.FN_NAME_CORE
-- Outputs : CURATED.BLOCK_KEY      - every blocking key of every matchable record
--           CURATED.BLOCK_SKIPPED  - oversized blocks left out of pairing (audit)
--           CURATED.CANDIDATE_PAIR - one row per candidate pair
--           CURATED.MATCH_FEATURE, CURATED.MATCH_DECISION,
--           AUDIT.MATCH_EVIDENCE, AUDIT.EXCEPTION_QUEUE (empty contract tables)
--           one row in AUDIT.PIPELINE_RUN (step '04_candidates')
-- Notes   : Idempotent (CREATE OR REPLACE for this step's outputs,
--           CREATE TABLE IF NOT EXISTS for the contract tables). Rule version
--           'block_v1'. Tests: tests/sql/test_candidates.sql.
-- =============================================================================

USE DATABASE KENDRIX;

-- One RUN_ID for this run, shared by every row and the audit log entry.
-- SET only accepts constants or subqueries, so function calls are wrapped in (SELECT ...).
SET RUN_ID = (SELECT UUID_STRING());
SET STARTED_AT = (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

-- A block shared by more than this many records is too generic to be evidence.
-- n records give n(n-1)/2 pairs: 200 records = 19,900 pairs from ONE value.
-- A genuine organisation is never 200 records in our two sources, so a value
-- that common (an umbrella body's 0800 number, a busy postcode + common name
-- start) only adds noise.
SET MAX_BLOCK_SIZE = 200;

-- -----------------------------------------------------------------------------
-- 1) CURATED.BLOCK_KEY: one row per record per blocking key.
--    Only IS_MATCHABLE records (no name = nothing to compare) and only non-null
--    values (NULL must never "match" NULL).
--    ALL keys are kept here, including oversized ones; oversized blocks are
--    filtered out in step 3. Keeping them lets the tests re-check exactly which
--    blocks each pair shares.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CURATED.BLOCK_KEY AS
WITH
src AS (
    SELECT *
    FROM STAGING.ORGANISATION_STD
    WHERE IS_MATCHABLE
),

-- Same area + same start of name. NAME_CORE is used because 'THE' and legal
-- form words are already stripped, so the first 4 letters carry meaning.
-- Catches spelling variants of one name at one address ('OTAGO RUGBY' vs
-- 'OTAGO RUGBY FOOTBALL UNION') that NAME_EXACT would miss.
blk_postcode_name4 AS (
    SELECT RECORD_KEY, 'POSTCODE_NAME4' AS BLOCK_TYPE,
           POSTCODE || '|' || LEFT(NAME_CORE, 4) AS BLOCK_VALUE
    FROM src
    WHERE POSTCODE IS NOT NULL AND NAME_CORE IS NOT NULL
),

-- Same phone number (already normalised to local 0... form in step 03).
blk_phone AS (
    SELECT RECORD_KEY, 'PHONE' AS BLOCK_TYPE, PHONE_CLEAN AS BLOCK_VALUE
    FROM src
    WHERE PHONE_CLEAN IS NOT NULL
),

-- Same email address, but not on free-mail or shared trustee-company domains:
-- those addresses are often used by many unrelated charities (one accountant
-- or trustee company runs dozens), so sharing one is not evidence.
blk_email AS (
    SELECT RECORD_KEY, 'EMAIL' AS BLOCK_TYPE, EMAIL_CLEAN AS BLOCK_VALUE
    FROM src
    WHERE EMAIL_CLEAN IS NOT NULL
      AND IS_GENERIC_EMAIL_DOMAIN = FALSE
),

-- Same website host. Excluded:
--  - values with no '.', which are junk ('n/a', 'none'), not hosts;
--  - generic hosting/social hosts where the host alone says nothing about the
--    owner (facebook.com/x and facebook.com/y are different organisations);
--  - any subdomain of facebook.com / google.com (m.facebook.com,
--    business.facebook.com) for the same reason.
-- Per-owner subdomains such as x.wixsite.com or x.blogspot.com are KEPT: each
-- one is a single site. If one is shared by many records anyway, the
-- MAX_BLOCK_SIZE cap removes it.
blk_website AS (
    SELECT RECORD_KEY, 'WEBSITE' AS BLOCK_TYPE, WEBSITE_DOMAIN AS BLOCK_VALUE
    FROM src
    WHERE WEBSITE_DOMAIN IS NOT NULL
      AND CONTAINS(WEBSITE_DOMAIN, '.')
      AND WEBSITE_DOMAIN NOT IN ('facebook.com', 'google.com', 'sites.google.com',
                                 'wixsite.com', 'wordpress.com', 'blogspot.com', 'weebly.com')
      AND NOT REGEXP_LIKE(WEBSITE_DOMAIN, '.*[.](facebook|google)[.]com')
),

-- Same name core: 'X Trust' and 'X Charitable Trust' meet here.
blk_name_exact AS (
    SELECT RECORD_KEY, 'NAME_EXACT' AS BLOCK_TYPE, NAME_CORE AS BLOCK_VALUE
    FROM src
    WHERE NAME_CORE IS NOT NULL
),

-- Alternative names (other/trading/previous names) as extra NAME_EXACT keys,
-- so a record's former or trading name can meet another record's current name.
-- ALT_NAMES already hold FN_NAME_CLEAN output, so only the core step is applied
-- (same rule as NAME_CORE, keeping the two comparable).
blk_alt_name AS (
    SELECT s.RECORD_KEY, 'NAME_EXACT' AS BLOCK_TYPE,
           STAGING.FN_NAME_CORE(f.VALUE::VARCHAR) AS BLOCK_VALUE
    FROM src s,
         LATERAL FLATTEN(INPUT => s.ALT_NAMES) f
    WHERE f.VALUE IS NOT NULL
),

-- Same NZBN. This is the production path: an NZBN is a real identifier, so
-- records sharing one must be compared. The evaluation step measures matching
-- WITHOUT this block (CANDIDATE_PAIR.ONLY_NZBN_BLOCK) to stay honest: a shared
-- NZBN is close to the answer itself, so counting those pairs would flatter
-- how well names/addresses/contacts find matches.
blk_nzbn AS (
    SELECT RECORD_KEY, 'NZBN' AS BLOCK_TYPE, NZBN AS BLOCK_VALUE
    FROM src
    WHERE NZBN IS NOT NULL
),

all_keys AS (
    SELECT * FROM blk_postcode_name4
    UNION ALL SELECT * FROM blk_phone
    UNION ALL SELECT * FROM blk_email
    UNION ALL SELECT * FROM blk_website
    UNION ALL SELECT * FROM blk_name_exact
    UNION ALL SELECT * FROM blk_alt_name
    UNION ALL SELECT * FROM blk_nzbn
)

-- DISTINCT: an alt name whose core equals the record's own NAME_CORE would
-- otherwise give the same key twice.
SELECT DISTINCT
    RECORD_KEY::VARCHAR                             AS RECORD_KEY,
    BLOCK_TYPE::VARCHAR                             AS BLOCK_TYPE,
    BLOCK_VALUE::VARCHAR                            AS BLOCK_VALUE,
    $RUN_ID::VARCHAR                                AS RUN_ID
FROM all_keys
WHERE BLOCK_VALUE IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2) CURATED.BLOCK_SKIPPED: blocks shared by more than MAX_BLOCK_SIZE records.
--    They are left out of pairing (see the MAX_BLOCK_SIZE comment above) and
--    recorded here so the audit shows exactly what was dropped and why.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CURATED.BLOCK_SKIPPED AS
SELECT
    BLOCK_TYPE,
    BLOCK_VALUE,
    COUNT(DISTINCT RECORD_KEY)                      AS RECORD_COUNT,
    $RUN_ID::VARCHAR                                AS RUN_ID
FROM CURATED.BLOCK_KEY
GROUP BY BLOCK_TYPE, BLOCK_VALUE
HAVING COUNT(DISTINCT RECORD_KEY) > $MAX_BLOCK_SIZE;

-- -----------------------------------------------------------------------------
-- 3) CURATED.CANDIDATE_PAIR: one row per pair of records sharing at least one
--    non-oversized block.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CURATED.CANDIDATE_PAIR AS
WITH
-- Blocking keys minus the oversized blocks.
kept AS (
    SELECT b.RECORD_KEY, b.BLOCK_TYPE, b.BLOCK_VALUE
    FROM CURATED.BLOCK_KEY b
    WHERE NOT EXISTS (
        SELECT 1 FROM CURATED.BLOCK_SKIPPED s
        WHERE s.BLOCK_TYPE = b.BLOCK_TYPE AND s.BLOCK_VALUE = b.BLOCK_VALUE
    )
),

-- Every two records in the same block. LEFT_KEY < RIGHT_KEY removes self-pairs
-- (A,A) and mirror duplicates (B,A when A,B already exists).
pair_blocks AS (
    SELECT l.RECORD_KEY AS LEFT_KEY, r.RECORD_KEY AS RIGHT_KEY, l.BLOCK_TYPE
    FROM kept l
    JOIN kept r
      ON  r.BLOCK_TYPE  = l.BLOCK_TYPE
      AND r.BLOCK_VALUE = l.BLOCK_VALUE
      AND l.RECORD_KEY  < r.RECORD_KEY
),

-- One row per pair. A pair can share several blocks; which block types it
-- shares is useful evidence later (and lets the evaluation drop NZBN-only pairs).
-- BLOCK_COUNT = number of distinct block TYPES shared.
pairs AS (
    SELECT
        LEFT_KEY,
        RIGHT_KEY,
        ARRAY_SORT(ARRAY_AGG(DISTINCT BLOCK_TYPE))  AS BLOCK_TYPES,
        COUNT(DISTINCT BLOCK_TYPE)                  AS BLOCK_COUNT
    FROM pair_blocks
    GROUP BY LEFT_KEY, RIGHT_KEY
)

SELECT
    SHA2(p.LEFT_KEY || '|' || p.RIGHT_KEY)::VARCHAR AS PAIR_ID,
    p.LEFT_KEY::VARCHAR                             AS LEFT_KEY,
    p.RIGHT_KEY::VARCHAR                            AS RIGHT_KEY,
    l.SOURCE_SYSTEM::VARCHAR                        AS LEFT_SOURCE,
    r.SOURCE_SYSTEM::VARCHAR                        AS RIGHT_SOURCE,
    -- 'CHR:' sorts before 'COS:', so in a cross-source pair the charity is
    -- always on the left and 'COS-CHR' cannot occur.
    CASE
        WHEN l.SOURCE_SYSTEM = 'CHARITIES_REGISTER' AND r.SOURCE_SYSTEM = 'CHARITIES_REGISTER' THEN 'CHR-CHR'
        WHEN l.SOURCE_SYSTEM = 'COMPANIES_OFFICE'   AND r.SOURCE_SYSTEM = 'COMPANIES_OFFICE'   THEN 'COS-COS'
        ELSE 'CHR-COS'
    END::VARCHAR                                    AS PAIR_TYPE,
    p.BLOCK_TYPES::ARRAY                            AS BLOCK_TYPES,
    p.BLOCK_COUNT::NUMBER                           AS BLOCK_COUNT,
    -- TRUE when the pair was only found through the NZBN block, so the
    -- evaluation can measure matching without the identifier.
    (p.BLOCK_COUNT = 1 AND ARRAY_CONTAINS('NZBN'::VARIANT, p.BLOCK_TYPES))::BOOLEAN
                                                    AS ONLY_NZBN_BLOCK,
    $RUN_ID::VARCHAR                                AS RUN_ID,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ              AS CREATED_AT
FROM pairs p
JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY;

-- -----------------------------------------------------------------------------
-- 4) Contract tables, filled by later steps (05 features, 06 matching, review).
--    Created here so column names and types are agreed before anyone writes
--    to them. IF NOT EXISTS keeps their data across re-runs of this file; the
--    flip side is that a column change later needs an explicit ALTER TABLE.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CURATED.MATCH_FEATURE (
    PAIR_ID        VARCHAR       COMMENT 'CANDIDATE_PAIR.PAIR_ID',
    NAME_JW        NUMBER(5,2)   COMMENT 'Jaro-Winkler similarity of NAME_CLEAN, 0-100',
    NAME_CORE_JW   NUMBER(5,2)   COMMENT 'Jaro-Winkler similarity of NAME_CORE, 0-100',
    ALT_NAME_JW    NUMBER(5,2)   COMMENT 'Best Jaro-Winkler similarity between any name/alt name of one side and any of the other, 0-100',
    ADDRESS_JW     NUMBER(5,2)   COMMENT 'Jaro-Winkler similarity of ADDRESS_LINE_CLEAN, 0-100; NULL if missing on either side',
    POSTCODE_EQ    BOOLEAN       COMMENT 'POSTCODE equal; NULL = no evidence (missing on one side)',
    CITY_EQ        BOOLEAN       COMMENT 'CITY equal; NULL = no evidence (missing on one side)',
    PHONE_EQ       BOOLEAN       COMMENT 'PHONE_CLEAN equal; NULL = no evidence (missing on one side)',
    EMAIL_EQ       BOOLEAN       COMMENT 'EMAIL_CLEAN equal (non-generic domains only); NULL = no evidence',
    WEBSITE_EQ     BOOLEAN       COMMENT 'WEBSITE_DOMAIN equal; NULL = no evidence (missing on one side)',
    NZBN_EQ        BOOLEAN       COMMENT 'NZBN equal; NULL = no evidence (missing on one side)',
    COMPANY_NO_EQ  BOOLEAN       COMMENT 'COMPANY_NO equal; NULL = no evidence (missing on one side)',
    RUN_ID         VARCHAR       COMMENT 'Pipeline run that produced this row'
);

CREATE TABLE IF NOT EXISTS CURATED.MATCH_DECISION (
    PAIR_ID        VARCHAR       COMMENT 'CANDIDATE_PAIR.PAIR_ID',
    SCORE          NUMBER(5,2)   COMMENT 'Match score, 0-100',
    DECISION       VARCHAR       COMMENT 'AUTO_MATCH / REVIEW / NO_MATCH',
    RULE_VERSION   VARCHAR       COMMENT 'Version of the scoring rules used',
    TOP_REASONS    ARRAY         COMMENT 'Features that contributed most to the score, most important first',
    RUN_ID         VARCHAR       COMMENT 'Pipeline run that produced this row',
    DECIDED_AT     TIMESTAMP_NTZ COMMENT 'When the decision was made'
);

CREATE TABLE IF NOT EXISTS AUDIT.MATCH_EVIDENCE (
    PAIR_ID        VARCHAR       COMMENT 'CANDIDATE_PAIR.PAIR_ID',
    FEATURE        VARCHAR       COMMENT 'Feature name, e.g. NAME_JW, PHONE_EQ',
    LEFT_VALUE     VARCHAR       COMMENT 'Value compared on the left record',
    RIGHT_VALUE    VARCHAR       COMMENT 'Value compared on the right record',
    SIMILARITY     NUMBER(5,2)   COMMENT 'Similarity for this feature, 0-100',
    WEIGHT         NUMBER(5,2)   COMMENT 'Weight of this feature in the score',
    CONTRIBUTION   NUMBER(6,2)   COMMENT 'Points this feature added to the score (can be negative)',
    RUN_ID         VARCHAR       COMMENT 'Pipeline run that produced this row'
);

CREATE TABLE IF NOT EXISTS AUDIT.EXCEPTION_QUEUE (
    EXCEPTION_ID    VARCHAR       COMMENT 'Unique id of the exception (UUID)',
    PAIR_ID         VARCHAR       COMMENT 'CANDIDATE_PAIR.PAIR_ID, when the exception is about a pair',
    RECORD_KEY      VARCHAR       COMMENT 'ORGANISATION_STD.RECORD_KEY, when the exception is about one record',
    REASON_CODE     VARCHAR       COMMENT 'Why this needs a human, e.g. REVIEW_SCORE, CONFLICTING_NZBN',
    SCORE           NUMBER(5,2)   COMMENT 'Match score at the time of queuing, 0-100',
    STATUS          VARCHAR DEFAULT 'OPEN' COMMENT 'OPEN / CLOSED',
    REVIEWER        VARCHAR       COMMENT 'Who reviewed it',
    REVIEW_DECISION VARCHAR       COMMENT 'Reviewer outcome, e.g. MATCH / NO_MATCH',
    REVIEWED_AT     TIMESTAMP_NTZ COMMENT 'When it was reviewed',
    RUN_ID          VARCHAR       COMMENT 'Pipeline run that queued it'
);

-- -----------------------------------------------------------------------------
-- 5) Audit log row. SUCCESS if pairs were produced and the count is below
--    2,000,000: zero means blocking broke, millions means a block exploded
--    and the later steps would not finish on an XSMALL warehouse.
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.PIPELINE_RUN (RUN_ID, STEP, STARTED_AT, FINISHED_AT, ROWS_OUT, RULE_VERSION, STATUS, NOTES)
SELECT $RUN_ID, '04_candidates',
       $STARTED_AT,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
       p.n, 'block_v1',
       IFF(p.n > 0 AND p.n < 2000000, 'SUCCESS', 'FAIL'),
       'blocks_skipped=' || s.n || ', max_block_size=' || $MAX_BLOCK_SIZE
FROM (SELECT COUNT(*) n FROM CURATED.CANDIDATE_PAIR) p,
     (SELECT COUNT(*) n FROM CURATED.BLOCK_SKIPPED) s;

-- -----------------------------------------------------------------------------
-- 6) Summary (last, so this result is what you see in Snowsight).
--    One (METRIC, VALUE) table. A pair counts under every block type it
--    shares, so the pairs_block_* rows add up to more than total_pairs.
-- -----------------------------------------------------------------------------
SELECT METRIC, VALUE
FROM (
    SELECT 1 AS SORT_ORDER, 'total_pairs' AS METRIC, COUNT(*) AS VALUE
    FROM CURATED.CANDIDATE_PAIR

    UNION ALL
    -- VALUES list so a pair type with 0 pairs still shows as 0.
    SELECT 2, 'pairs_' || t.PAIR_TYPE, COUNT(p.PAIR_ID)
    FROM (SELECT * FROM VALUES ('CHR-CHR'), ('CHR-COS'), ('COS-COS') AS v(PAIR_TYPE)) t
    LEFT JOIN CURATED.CANDIDATE_PAIR p ON p.PAIR_TYPE = t.PAIR_TYPE
    GROUP BY t.PAIR_TYPE

    UNION ALL
    SELECT 3, 'pairs_block_' || f.VALUE::VARCHAR, COUNT(*)
    FROM CURATED.CANDIDATE_PAIR p,
         LATERAL FLATTEN(INPUT => p.BLOCK_TYPES) f
    GROUP BY f.VALUE::VARCHAR

    UNION ALL
    SELECT 4, 'only_nzbn_block_pairs', COUNT_IF(ONLY_NZBN_BLOCK)
    FROM CURATED.CANDIDATE_PAIR

    UNION ALL
    SELECT 5, 'blocks_skipped', COUNT(*)
    FROM CURATED.BLOCK_SKIPPED

    UNION ALL
    SELECT 6, 'largest_kept_block_size', COALESCE(MAX(n), 0)
    FROM (
        SELECT COUNT(DISTINCT b.RECORD_KEY) AS n
        FROM CURATED.BLOCK_KEY b
        WHERE NOT EXISTS (
            SELECT 1 FROM CURATED.BLOCK_SKIPPED s
            WHERE s.BLOCK_TYPE = b.BLOCK_TYPE AND s.BLOCK_VALUE = b.BLOCK_VALUE
        )
        GROUP BY b.BLOCK_TYPE, b.BLOCK_VALUE
    )
)
ORDER BY SORT_ORDER, METRIC;
