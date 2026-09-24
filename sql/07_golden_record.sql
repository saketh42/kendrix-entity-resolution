-- =============================================================================
-- 07_golden_record.sql
-- Purpose : Golden record. Groups records linked by AUTO_MATCH pairs into
--           entities (clusters), gives each entity a stable MASTER_ID, picks the
--           best value for every field (survivorship) and exposes a lineage view
--           from each master record back to every original RAW row.
-- Owner   : Data Engineer (Shubham)
-- Inputs  : STAGING.ORGANISATION_STD   (47,709 records, built by sql/03)
--           CURATED.CANDIDATE_PAIR     (built by sql/04)
--           CURATED.MATCH_DECISION     (built by sql/06, rule 'score_v5')
--           AUDIT.EXCEPTION_QUEUE      (built by sql/06)
--           RAW.CHARITIES_ORGANISATIONS, RAW.COMPANIES_OFFICE (lineage only)
-- Outputs : CURATED.TMP_CLUSTER_EDGE   - AUTO_MATCH edges (TEMPORARY)
--           CURATED.CLUSTER_WORK       - one row per record: its cluster label
--           CURATED.ENTITY_XREF        - one row per record: its MASTER_ID
--           CURATED.MASTER_ORGANISATION - one row per entity (golden record)
--           CURATED.V_ENTITY_LINEAGE   - master -> xref -> staging -> raw
--           AUDIT.EXCEPTION_QUEUE      - one 'CHAIN_NZBN_CONFLICT' row per member
--                                        record of a master with two NZBNs
--           one row in AUDIT.PIPELINE_RUN (step '07_golden_record')
-- Notes   : Idempotent (CREATE OR REPLACE; earlier CHAIN_NZBN_CONFLICT queue
--           rows are deleted before being re-created). Rule version 'surv_v1'.
--           Only AUTO_MATCH pairs link records. REVIEW pairs are NEVER merged:
--           a human has not decided yet, so they stay separate masters and the
--           master is flagged HAS_OPEN_REVIEW instead.
--           Tests: tests/sql/test_golden_record.sql.
-- =============================================================================

USE DATABASE KENDRIX;

-- One RUN_ID for this run, shared by every row and the audit log entry.
-- SET only accepts constants or subqueries, so function calls are wrapped in (SELECT ...).
SET RUN_ID       = (SELECT UUID_STRING());
SET STARTED_AT   = (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
SET RULE_VERSION = 'surv_v1';

-- A cluster with more than this many records is flagged IS_LARGE_CLUSTER.
-- Linking is transitive (A-B and B-C puts A and C together even if A and C
-- look nothing alike), so one weak link can chain unrelated records into one
-- big cluster. No real organisation has this many records in our two
-- sources, so a big cluster is a signal for a human to check it.
SET LARGE_CLUSTER = 10;

-- -----------------------------------------------------------------------------
-- 1) Edges: AUTO_MATCH pairs only, in BOTH directions.
--    REVIEW and NO_MATCH pairs are left out on purpose: an unreviewed pair
--    must never merge two records. Both directions (A->B and B->A) so a label
--    can flow either way along a link in step 3.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE CURATED.TMP_CLUSTER_EDGE AS
WITH
auto_pairs AS (
    SELECT p.PAIR_ID, p.LEFT_KEY, p.RIGHT_KEY, d.SCORE, d.DECISION_PATH
    FROM CURATED.MATCH_DECISION d
    JOIN CURATED.CANDIDATE_PAIR p ON p.PAIR_ID = d.PAIR_ID
    WHERE d.DECISION = 'AUTO_MATCH'
)
SELECT PAIR_ID, LEFT_KEY  AS FROM_KEY, RIGHT_KEY AS TO_KEY, SCORE, DECISION_PATH FROM auto_pairs
UNION ALL
SELECT PAIR_ID, RIGHT_KEY AS FROM_KEY, LEFT_KEY  AS TO_KEY, SCORE, DECISION_PATH FROM auto_pairs;

-- -----------------------------------------------------------------------------
-- 2) Work table: EVERY staging record starts as its own cluster
--    (CLUSTER_ID = its own RECORD_KEY). Records with no AUTO_MATCH edge never
--    change, so they end up as singletons without any special handling.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CURATED.CLUSTER_WORK AS
SELECT
    RECORD_KEY::VARCHAR                             AS RECORD_KEY,
    RECORD_KEY::VARCHAR                             AS CLUSTER_ID
FROM STAGING.ORGANISATION_STD;

-- -----------------------------------------------------------------------------
-- 3) Label propagation (connected components).
--    Each round, every record takes the SMALLEST cluster label among itself
--    and its direct neighbours. After enough rounds every record in a group of
--    linked records (directly or via others: A-B, B-C) carries the same label:
--    the smallest RECORD_KEY in the group. Rounds needed = the longest chain in
--    a cluster, so most clusters settle in 1-3 rounds.
--    - "n.NEW_ID < w.CLUSTER_ID" is LEAST(own, min neighbour): only rows that
--      really change are updated, so SQLROWCOUNT = number of changed rows.
--    - Stops when a round changes nothing, or after 30 rounds as a safety cap
--      against an endless loop. (30 is written as a literal because session
--      variables are not used inside the $$ block.) Hitting the cap would leave
--      clusters split; step 3b checks for that and the audit row then FAILs.
--    - Returns the number of rounds run.
-- -----------------------------------------------------------------------------
EXECUTE IMMEDIATE $$
DECLARE
    iter    INTEGER DEFAULT 0;
    changed INTEGER DEFAULT 1;
BEGIN
    WHILE (changed > 0 AND iter < 30) DO
        iter := iter + 1;
        UPDATE CURATED.CLUSTER_WORK w
           SET CLUSTER_ID = n.NEW_ID
          FROM (
                SELECT e.FROM_KEY, MIN(c.CLUSTER_ID) AS NEW_ID
                FROM CURATED.TMP_CLUSTER_EDGE e
                JOIN CURATED.CLUSTER_WORK c ON c.RECORD_KEY = e.TO_KEY
                GROUP BY e.FROM_KEY
               ) n
         WHERE w.RECORD_KEY = n.FROM_KEY
           AND n.NEW_ID < w.CLUSTER_ID;
        changed := SQLROWCOUNT;
    END WHILE;
    RETURN iter;
END;
$$;

-- The block's return value is the result of the previous statement.
SET LP_ITERATIONS = (SELECT $1::NUMBER FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

-- 3b) Converged = no AUTO_MATCH edge joins two different clusters. If the
--     30-round cap was hit before this was true, clusters are incomplete.
SET CONVERGED = (
    SELECT COUNT(*) = 0
    FROM CURATED.TMP_CLUSTER_EDGE e
    JOIN CURATED.CLUSTER_WORK a ON a.RECORD_KEY = e.FROM_KEY
    JOIN CURATED.CLUSTER_WORK b ON b.RECORD_KEY = e.TO_KEY
    WHERE a.CLUSTER_ID <> b.CLUSTER_ID
);

-- -----------------------------------------------------------------------------
-- 4) CURATED.ENTITY_XREF: one row per staging record -> its MASTER_ID.
--    MASTER_ID is a hash of the cluster label (the smallest RECORD_KEY in the
--    cluster), so it stays the same across re-runs as long as that seed record
--    stays in the cluster. 'CHR:' sorts before 'COS:', so a charity record is
--    usually the seed of a cross-source cluster.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CURATED.ENTITY_XREF AS
WITH
cluster_size AS (
    SELECT CLUSTER_ID, COUNT(*) AS MEMBER_COUNT
    FROM CURATED.CLUSTER_WORK
    GROUP BY CLUSTER_ID
),

-- Why each record is linked: its strongest AUTO_MATCH pair (LINK_CONFIDENCE)
-- and the rules that produced its links (LINK_RULES, e.g. ID_MATCH / FUZZY),
-- so the reason is visible without going back to sql/06's tables.
link_conf AS (
    SELECT
        FROM_KEY                                    AS RECORD_KEY,
        MAX(SCORE)                                  AS LINK_CONFIDENCE,
        ARRAY_SORT(ARRAY_AGG(DISTINCT DECISION_PATH)) AS LINK_RULES
    FROM CURATED.TMP_CLUSTER_EDGE
    GROUP BY FROM_KEY
)

SELECT
    ('ORG-' || LEFT(SHA2(w.CLUSTER_ID), 12))::VARCHAR AS MASTER_ID,
    w.CLUSTER_ID::VARCHAR                           AS CLUSTER_ID,
    w.RECORD_KEY::VARCHAR                           AS RECORD_KEY,
    s.SOURCE_SYSTEM::VARCHAR                        AS SOURCE_SYSTEM,
    s.SOURCE_RECORD_ID::VARCHAR                     AS SOURCE_RECORD_ID,
    CASE
        WHEN cs.MEMBER_COUNT = 1          THEN 'SINGLETON'
        -- The record whose key became the cluster label.
        WHEN w.RECORD_KEY = w.CLUSTER_ID  THEN 'SEED'
        ELSE 'AUTO_MATCH'
    END::VARCHAR                                    AS LINK_TYPE,
    -- A record in a multi-record cluster always has at least one AUTO_MATCH
    -- edge (that is how it got there), so this is only NULL for singletons.
    IFF(cs.MEMBER_COUNT = 1, NULL, lc.LINK_CONFIDENCE)::NUMBER(5,2) AS LINK_CONFIDENCE,
    IFF(cs.MEMBER_COUNT = 1, NULL, lc.LINK_RULES)::ARRAY            AS LINK_RULES,
    $RULE_VERSION::VARCHAR                          AS RULE_VERSION,
    $RUN_ID::VARCHAR                                AS RUN_ID
FROM CURATED.CLUSTER_WORK w
JOIN STAGING.ORGANISATION_STD s ON s.RECORD_KEY = w.RECORD_KEY
JOIN cluster_size cs            ON cs.CLUSTER_ID = w.CLUSTER_ID
LEFT JOIN link_conf lc          ON lc.RECORD_KEY = w.RECORD_KEY;

-- -----------------------------------------------------------------------------
-- 5) CURATED.MASTER_ORGANISATION: one row per MASTER_ID (the golden record).
--    Survivorship = which member record each field is taken from. Every rule
--    ends in a RECORD_KEY tie-break so a re-run always picks the same value.
-- -----------------------------------------------------------------------------

-- Remove this step's queue rows from any earlier run FIRST (they are
-- re-created in step 5b), so a re-run does not duplicate them. Done before the
-- master build so stale rows cannot set HAS_OPEN_REVIEW via open_review below.
-- Only this step's reason code is touched; sql/06's rows are left alone.
DELETE FROM AUDIT.EXCEPTION_QUEUE
WHERE REASON_CODE = 'CHAIN_NZBN_CONFLICT';

CREATE OR REPLACE TABLE CURATED.MASTER_ORGANISATION AS
WITH
-- Records that appear in an OPEN exception: either side of a queued pair, or
-- a record-level exception (RECORD_KEY column; unused by sql/06 today, but
-- part of the queue contract from sql/04).
open_review AS (
    SELECT p.LEFT_KEY AS RECORD_KEY
    FROM AUDIT.EXCEPTION_QUEUE q
    JOIN CURATED.CANDIDATE_PAIR p ON p.PAIR_ID = q.PAIR_ID
    WHERE q.STATUS = 'OPEN'
    UNION
    SELECT p.RIGHT_KEY
    FROM AUDIT.EXCEPTION_QUEUE q
    JOIN CURATED.CANDIDATE_PAIR p ON p.PAIR_ID = q.PAIR_ID
    WHERE q.STATUS = 'OPEN'
    UNION
    SELECT q.RECORD_KEY
    FROM AUDIT.EXCEPTION_QUEUE q
    WHERE q.STATUS = 'OPEN'
      AND q.RECORD_KEY IS NOT NULL
),

-- Every member record with its staging values.
members AS (
    SELECT
        x.MASTER_ID, x.RECORD_KEY, x.LINK_CONFIDENCE,
        s.SOURCE_SYSTEM, s.NAME_RAW, s.CHARITY_REG_NO, s.NZBN,
        s.ADDRESS_LINE_CLEAN, s.SUBURB, s.CITY, s.POSTCODE,
        s.PHONE_CLEAN, s.EMAIL_CLEAN, s.WEBSITE_DOMAIN,
        s.ENTITY_STATUS, s.REGISTERED_DATE,
        (o.RECORD_KEY IS NOT NULL)                  AS IN_OPEN_REVIEW
    FROM CURATED.ENTITY_XREF x
    JOIN STAGING.ORGANISATION_STD s ON s.RECORD_KEY = x.RECORD_KEY
    LEFT JOIN open_review o         ON o.RECORD_KEY = x.RECORD_KEY
),

-- MASTER_NAME: the name of the currently REGISTERED record, the most recently
-- registered one if several; if none is registered, the most recently
-- registered record of any status. A registered, recent record is the one
-- most likely to carry the organisation's current legal name. NAME_RAW (as
-- received) is kept for display, not the cleaned upper-case form.
-- The first sort key (records with a name first) is only a safety net:
-- unnamed records are not matchable, so they are always singletons.
name_pick AS (
    SELECT MASTER_ID, NAME_RAW AS MASTER_NAME, RECORD_KEY AS NAME_SOURCE_KEY
    FROM members
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY MASTER_ID
        ORDER BY IFF(NAME_RAW IS NULL, 1, 0),
                 IFF(ENTITY_STATUS = 'REGISTERED', 0, 1),
                 REGISTERED_DATE DESC NULLS LAST,
                 RECORD_KEY) = 1
),

-- NZBN: the value most members agree on (majority vote). Ties go to the
-- smallest NZBN so the choice is repeatable. More than one distinct NZBN in
-- one master is flagged NZBN_CONFLICT in step 'final' below.
nzbn_pick AS (
    SELECT MASTER_ID, NZBN
    FROM members
    WHERE NZBN IS NOT NULL
    GROUP BY MASTER_ID, NZBN
    QUALIFY ROW_NUMBER() OVER (PARTITION BY MASTER_ID ORDER BY COUNT(*) DESC, NZBN) = 1
),

-- ADDRESS: all four parts from ONE record, the most recently registered one
-- that has any address part. Taking line, suburb, city and postcode from
-- different records could build an address that does not exist (same rule
-- as the street/postal choice in sql/03).
address_pick AS (
    SELECT MASTER_ID, ADDRESS_LINE_CLEAN, SUBURB, CITY, POSTCODE
    FROM members
    WHERE COALESCE(ADDRESS_LINE_CLEAN, SUBURB, CITY, POSTCODE) IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY MASTER_ID
        ORDER BY REGISTERED_DATE DESC NULLS LAST, RECORD_KEY) = 1
),

-- Everything else in one pass per master.
-- PHONE / EMAIL / WEBSITE: from the most recently registered record that HAS
-- the value (newer registrations are more likely to hold current contacts).
-- ARRAY_AGG skips NULLs, so element [0] of the ordered array is exactly that.
agg AS (
    SELECT
        MASTER_ID,
        (ARRAY_AGG(PHONE_CLEAN)    WITHIN GROUP (ORDER BY REGISTERED_DATE DESC NULLS LAST, RECORD_KEY))[0]::VARCHAR AS PHONE,
        (ARRAY_AGG(EMAIL_CLEAN)    WITHIN GROUP (ORDER BY REGISTERED_DATE DESC NULLS LAST, RECORD_KEY))[0]::VARCHAR AS EMAIL,
        (ARRAY_AGG(WEBSITE_DOMAIN) WITHIN GROUP (ORDER BY REGISTERED_DATE DESC NULLS LAST, RECORD_KEY))[0]::VARCHAR AS WEBSITE,
        -- Two different NZBNs = two legal entities: linking chained them together.
        COUNT(DISTINCT NZBN) > 1                    AS NZBN_CONFLICT,
        -- Keep ALL registration numbers: a master can legitimately cover
        -- several charity registrations, and none should disappear.
        ARRAY_SORT(ARRAY_AGG(DISTINCT CHARITY_REG_NO)) AS CHARITY_REG_NOS,
        ARRAY_SORT(ARRAY_AGG(DISTINCT SOURCE_SYSTEM))  AS SOURCE_SYSTEMS,
        COUNT(*)                                    AS MEMBER_COUNT,
        -- The weakest link in the cluster: its confidence is only as good as this.
        MIN(LINK_CONFIDENCE)                        AS MIN_LINK_CONFIDENCE,
        BOOLOR_AGG(IN_OPEN_REVIEW)                  AS HAS_OPEN_REVIEW,
        -- 'REGISTERED' if any member is still registered (the organisation is
        -- active in at least one register); otherwise the latest known status.
        IFF(COALESCE(BOOLOR_AGG(ENTITY_STATUS = 'REGISTERED'), FALSE),
            'REGISTERED',
            (ARRAY_AGG(ENTITY_STATUS) WITHIN GROUP (ORDER BY REGISTERED_DATE DESC NULLS LAST, RECORD_KEY))[0]::VARCHAR
        )                                           AS STATUS_SUMMARY
    FROM members
    GROUP BY MASTER_ID
)

SELECT
    a.MASTER_ID::VARCHAR                            AS MASTER_ID,
    n.MASTER_NAME::VARCHAR                          AS MASTER_NAME,
    n.NAME_SOURCE_KEY::VARCHAR                      AS NAME_SOURCE_KEY,
    z.NZBN::VARCHAR                                 AS NZBN,
    a.NZBN_CONFLICT::BOOLEAN                        AS NZBN_CONFLICT,
    ad.ADDRESS_LINE_CLEAN::VARCHAR                  AS ADDRESS_LINE,
    ad.SUBURB::VARCHAR                              AS SUBURB,
    ad.CITY::VARCHAR                                AS CITY,
    ad.POSTCODE::VARCHAR                            AS POSTCODE,
    a.PHONE::VARCHAR                                AS PHONE,
    a.EMAIL::VARCHAR                                AS EMAIL,
    a.WEBSITE::VARCHAR                              AS WEBSITE,
    a.CHARITY_REG_NOS::ARRAY                        AS CHARITY_REG_NOS,
    a.SOURCE_SYSTEMS::ARRAY                         AS SOURCE_SYSTEMS,
    a.MEMBER_COUNT::NUMBER                          AS MEMBER_COUNT,
    a.MIN_LINK_CONFIDENCE::NUMBER(5,2)              AS MIN_LINK_CONFIDENCE,
    COALESCE(a.HAS_OPEN_REVIEW, FALSE)::BOOLEAN     AS HAS_OPEN_REVIEW,
    (a.MEMBER_COUNT > $LARGE_CLUSTER)::BOOLEAN      AS IS_LARGE_CLUSTER,
    a.STATUS_SUMMARY::VARCHAR                       AS STATUS_SUMMARY,
    $RULE_VERSION::VARCHAR                          AS RULE_VERSION,
    $RUN_ID::VARCHAR                                AS RUN_ID,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ              AS BUILT_AT
FROM agg a
JOIN name_pick n          ON n.MASTER_ID  = a.MASTER_ID
LEFT JOIN nzbn_pick z     ON z.MASTER_ID  = a.MASTER_ID
LEFT JOIN address_pick ad ON ad.MASTER_ID = a.MASTER_ID;

-- -----------------------------------------------------------------------------
-- 5b) Chain merges with conflicting NZBNs -> review queue.
--     NZBN_CONFLICT = TRUE comes from chaining: A-B and B-C were each
--     auto-matched, but A and C carry different NZBNs, i.e. two legal
--     entities ended up in one master. We QUEUE these instead of silently
--     splitting them: which link is wrong (A-B or B-C) is a judgement a human
--     should make, and keeping the cluster intact preserves the evidence
--     (every member, its link confidence and rules in ENTITY_XREF) that the
--     reviewer needs. An automatic split could just as easily cut the right
--     link and hide the problem.
--     One row per member record (PAIR_ID NULL, RECORD_KEY set), so the
--     reviewer sees every record involved. SCORE is left NULL: the issue is
--     the cluster, not one pair's score.
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.EXCEPTION_QUEUE (EXCEPTION_ID, PAIR_ID, RECORD_KEY, REASON_CODE, SCORE, STATUS, RUN_ID)
SELECT
    UUID_STRING(),
    NULL,
    x.RECORD_KEY,
    'CHAIN_NZBN_CONFLICT',
    NULL,
    'OPEN',
    $RUN_ID
FROM CURATED.MASTER_ORGANISATION m
JOIN CURATED.ENTITY_XREF x ON x.MASTER_ID = m.MASTER_ID
WHERE m.NZBN_CONFLICT = TRUE;

-- The queue rows above were written after the master was built, so flag
-- those masters here: they now have an open review.
UPDATE CURATED.MASTER_ORGANISATION
   SET HAS_OPEN_REVIEW = TRUE
 WHERE NZBN_CONFLICT = TRUE;

-- -----------------------------------------------------------------------------
-- 6) CURATED.V_ENTITY_LINEAGE: one row per staging record, from its master
--    record back to the original RAW row (file name and load time), with how
--    and how strongly it was linked. Lets a regulator trace any master value
--    to the rows it came from.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW CURATED.V_ENTITY_LINEAGE AS
WITH
-- Charities: ORGANISATIONID is the primary key, one row per record.
chr_raw AS (
    SELECT NULLIF(TRIM(ORGANISATIONID), '') AS ORGANISATIONID,
           NAME, _SOURCE_FILE, _LOADED_AT
    FROM RAW.CHARITIES_ORGANISATIONS
),

-- Companies Office: the two exports overlap, so one NZBN can have two RAW
-- rows. Take the same row sql/03 kept (first export, then BUSINESS_NAME), so
-- lineage points at the row the staging record was actually built from and
-- the view keeps one row per record.
cos_first AS (
    SELECT NULLIF(TRIM(NZBN), '') AS NZBN,
           BUSINESS_NAME, EXPORT_FILE, _SOURCE_FILE, _LOADED_AT
    FROM RAW.COMPANIES_OFFICE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY NULLIF(TRIM(NZBN), '')
                               ORDER BY EXPORT_FILE, BUSINESS_NAME) = 1
)

SELECT
    m.MASTER_ID,
    m.MASTER_NAME,
    x.RECORD_KEY,
    x.SOURCE_SYSTEM,
    x.SOURCE_RECORD_ID,
    s.NAME_RAW,
    -- The name exactly as received in the source file.
    COALESCE(c.NAME, co.BUSINESS_NAME)              AS RAW_NAME,
    COALESCE(c._SOURCE_FILE, co._SOURCE_FILE)       AS RAW_SOURCE_FILE,
    COALESCE(c._LOADED_AT, co._LOADED_AT)           AS RAW_LOADED_AT,
    co.EXPORT_FILE                                  AS COS_EXPORT_FILE,
    x.LINK_TYPE,
    x.LINK_CONFIDENCE,
    x.LINK_RULES
FROM CURATED.ENTITY_XREF x
JOIN CURATED.MASTER_ORGANISATION m ON m.MASTER_ID  = x.MASTER_ID
JOIN STAGING.ORGANISATION_STD s    ON s.RECORD_KEY = x.RECORD_KEY
-- Each RAW table is joined only for its own source, so a charity id can never
-- accidentally match a Companies Office row.
LEFT JOIN chr_raw c
       ON x.SOURCE_SYSTEM = 'CHARITIES_REGISTER'
      AND c.ORGANISATIONID = x.SOURCE_RECORD_ID
LEFT JOIN cos_first co
       ON x.SOURCE_SYSTEM = 'COMPANIES_OFFICE'
      AND co.NZBN = x.SOURCE_RECORD_ID;

-- -----------------------------------------------------------------------------
-- 7) Audit log row. SUCCESS only if:
--    - every staging record is in ENTITY_XREF exactly once (none lost, none
--      duplicated),
--    - label propagation converged (no AUTO_MATCH pair split across masters),
--    - distinct MASTER_IDs = distinct clusters (the 12-character hash did not
--      collide and merge two clusters by accident).
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.PIPELINE_RUN (RUN_ID, STEP, STARTED_AT, FINISHED_AT, ROWS_OUT, RULE_VERSION, STATUS, NOTES)
SELECT $RUN_ID, '07_golden_record',
       $STARTED_AT,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
       m.n, $RULE_VERSION,
       IFF(x.n = s.n AND x.keys = s.n AND miss.n = 0
           AND $CONVERGED
           AND x.masters = x.clusters, 'SUCCESS', 'FAIL'),
       'staging=' || s.n || ', xref=' || x.n || ', masters=' || m.n
           || ', multi_record_masters=' || m.multi
           || ', iterations=' || $LP_ITERATIONS || ', converged=' || IFF($CONVERGED, 'yes', 'no')
FROM (SELECT COUNT(*) n FROM STAGING.ORGANISATION_STD) s,
     (SELECT COUNT(*) n,
             COUNT(DISTINCT RECORD_KEY) keys,
             COUNT(DISTINCT CLUSTER_ID) clusters,
             COUNT(DISTINCT MASTER_ID)  masters
      FROM CURATED.ENTITY_XREF) x,
     (SELECT COUNT(*) n
      FROM STAGING.ORGANISATION_STD st
      LEFT JOIN CURATED.ENTITY_XREF ex ON ex.RECORD_KEY = st.RECORD_KEY
      WHERE ex.RECORD_KEY IS NULL) miss,
     (SELECT COUNT(*) n, COUNT_IF(MEMBER_COUNT > 1) multi
      FROM CURATED.MASTER_ORGANISATION) m;

-- -----------------------------------------------------------------------------
-- 8) Summary (last, so this result is what you see in Snowsight).
--    One (METRIC, VALUE) table. The 5 examples are the LARGEST multi-record
--    masters: big clusters are where a chaining error would show, so they are
--    the ones most worth checking by eye. VALUE = MIN_LINK_CONFIDENCE.
-- -----------------------------------------------------------------------------
SELECT METRIC, VALUE
FROM (
    SELECT 1 AS SORT_ORDER, 'staging_records' AS METRIC, COUNT(*)::NUMBER(18,2) AS VALUE
    FROM STAGING.ORGANISATION_STD

    UNION ALL
    SELECT 2, 'master_entities', COUNT(*) FROM CURATED.MASTER_ORGANISATION

    UNION ALL
    SELECT 3, 'singletons', COUNT_IF(MEMBER_COUNT = 1) FROM CURATED.MASTER_ORGANISATION

    UNION ALL
    SELECT 4, 'multi_record_masters', COUNT_IF(MEMBER_COUNT > 1) FROM CURATED.MASTER_ORGANISATION

    UNION ALL
    SELECT 5, 'records_merged_away',
           (SELECT COUNT(*) FROM STAGING.ORGANISATION_STD)
         - (SELECT COUNT(*) FROM CURATED.MASTER_ORGANISATION)

    UNION ALL
    SELECT 6, 'largest_cluster_size', MAX(MEMBER_COUNT) FROM CURATED.MASTER_ORGANISATION

    UNION ALL
    SELECT 7, 'masters_nzbn_conflict', COUNT_IF(NZBN_CONFLICT) FROM CURATED.MASTER_ORGANISATION

    UNION ALL
    -- Member records queued for review because their master has two NZBNs (5b).
    SELECT 7, 'chain_nzbn_conflict_queued', COUNT(*)
    FROM AUDIT.EXCEPTION_QUEUE
    WHERE REASON_CODE = 'CHAIN_NZBN_CONFLICT'
      AND STATUS = 'OPEN'

    UNION ALL
    SELECT 8, 'masters_has_open_review', COUNT_IF(HAS_OPEN_REVIEW) FROM CURATED.MASTER_ORGANISATION

    UNION ALL
    SELECT 9, 'large_clusters', COUNT_IF(IS_LARGE_CLUSTER) FROM CURATED.MASTER_ORGANISATION

    UNION ALL
    SELECT 10, 'cross_source_masters',
           COUNT_IF(ARRAY_CONTAINS('CHARITIES_REGISTER'::VARIANT, SOURCE_SYSTEMS)
                AND ARRAY_CONTAINS('COMPANIES_OFFICE'::VARIANT, SOURCE_SYSTEMS))
    FROM CURATED.MASTER_ORGANISATION

    UNION ALL
    SELECT 11, 'label_propagation_iterations', $LP_ITERATIONS

    UNION ALL
    SELECT 12, METRIC, VALUE
    FROM (
        SELECT COALESCE(MASTER_NAME, MASTER_ID) || ' (' || MEMBER_COUNT || ' records)' AS METRIC,
               MIN_LINK_CONFIDENCE AS VALUE
        FROM CURATED.MASTER_ORGANISATION
        WHERE MEMBER_COUNT > 1
        ORDER BY MEMBER_COUNT DESC, MASTER_ID
        LIMIT 5
    )
)
ORDER BY SORT_ORDER, METRIC;
