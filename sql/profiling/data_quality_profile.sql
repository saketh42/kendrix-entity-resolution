-- =============================================================================
-- data_quality_profile.sql
-- Purpose : Profile data quality of both sources (RAW = before cleaning) and
--           the cleaning outcome (STAGING = after cleaning). Every check writes
--           one row to AUDIT.DQ_PROFILE, so docs/data_quality_report.md can be
--           filled in from one repeatable run instead of ad-hoc queries.
-- Owner   : Data Analyst (Esha)
-- Inputs  : RAW.CHARITIES_ORGANISATIONS (46,045 rows)
--           RAW.COMPANIES_OFFICE        (2,000 rows, overlapping exports)
--           STAGING.ORGANISATION_STD    (built by sql/03_standardisation.sql)
--           STAGING.FN_PHONE_IS_OVERSEAS (UDF from sql/03, reused so counts agree)
-- Outputs : AUDIT.DQ_PROFILE - one row per check, appended under a new RUN_ID.
-- Notes   : Read-only on RAW and STAGING. Safe to re-run: each run appends rows
--           with its own RUN_ID and never changes earlier runs.
--           RAW is all VARCHAR and the source CSV quotes every field, so blanks
--           are '' not NULL. Every "missing" check uses NULLIF(TRIM(col), '').
--           Run after sql/03_standardisation.sql. The LAST statement returns
--           this run's full results (Snowsight only shows the last result).
-- =============================================================================

USE DATABASE KENDRIX;

-- One RUN_ID and one timestamp shared by every row of this run.
-- SET only accepts constants or subqueries, so function calls are wrapped in (SELECT ...).
SET RUN_ID      = (SELECT UUID_STRING());
SET PROFILED_AT = (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

CREATE TABLE IF NOT EXISTS AUDIT.DQ_PROFILE (
    RUN_ID          VARCHAR,
    PROFILED_AT     TIMESTAMP_NTZ,
    SOURCE          VARCHAR,
    CHECK_NAME      VARCHAR,
    METRIC_VALUE    NUMBER(18,2),
    UNIT            VARCHAR,
    WHY_IT_MATTERS  VARCHAR
);

-- -----------------------------------------------------------------------------
-- 0) Row counts. Question: how big is each source, before and after cleaning?
--    STAGING Companies Office should be smaller than RAW (NZBN de-duplication).
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.DQ_PROFILE (RUN_ID, PROFILED_AT, SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS)
SELECT $RUN_ID, $PROFILED_AT, c.*
FROM (
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'row_count', COUNT(*), 'rows',
           'Baseline for every % below; expected 46,045.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.COMPANIES_OFFICE', 'row_count', COUNT(*), 'rows',
           'Baseline for every % below; expected 2,000 (two overlapping exports).'
    FROM RAW.COMPANIES_OFFICE
    UNION ALL
    SELECT 'STAGING.' || SOURCE_SYSTEM, 'row_count', COUNT(*), 'rows',
           'Records that go into matching; Companies Office should be 1,664 after NZBN dedupe.'
    FROM STAGING.ORGANISATION_STD
    GROUP BY SOURCE_SYSTEM
) c;

-- -----------------------------------------------------------------------------
-- 1) Completeness. Question: how often is each matching field filled in?
--    A field that is mostly blank cannot carry much match evidence.
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.DQ_PROFILE (RUN_ID, PROFILED_AT, SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS)
SELECT $RUN_ID, $PROFILED_AT, c.*
FROM (
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_NAME',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(NAME), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Name is the main match field; blank names cannot be matched.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_CHARITYREGISTRATIONNUMBER',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(CHARITYREGISTRATIONNUMBER), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Registration number links group members to their parent charity.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_NZBNNUMBER',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(NZBNNUMBER), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'NZBN is the only shared ID with the Companies Office; it limits exact matches.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_COMPANIESOFFICENUMBER',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(COMPANIESOFFICENUMBER), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Shows how many charities say they are also registered companies/societies.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_EMAILADDRESS1',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(EMAILADDRESS1), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Email is supporting evidence; only usable when present and not generic.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_TELEPHONE1',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(TELEPHONE1), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Phone is supporting evidence between charity records.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_WEBSITEURL',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(WEBSITEURL), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Website domain is strong evidence when two records share it.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_STREETADDRESSLINE1',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(STREETADDRESSLINE1), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Street address is compared with Companies Office physical address; postal is the fallback.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'pct_nonblank_STREETADDRESSPOSTCODE',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(STREETADDRESSPOSTCODE), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Postcode is used for blocking and as address evidence.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.COMPANIES_OFFICE', 'pct_nonblank_BUSINESS_NAME',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(BUSINESS_NAME), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Main match field; sole traders have none and fall back to TRADING_AS.'
    FROM RAW.COMPANIES_OFFICE
    UNION ALL
    SELECT 'RAW.COMPANIES_OFFICE', 'pct_nonblank_NZBN',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(NZBN), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'NZBN is the record key for this source and the exact-match ID.'
    FROM RAW.COMPANIES_OFFICE
    UNION ALL
    SELECT 'RAW.COMPANIES_OFFICE', 'pct_nonblank_TRADING_AS',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(TRADING_AS), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Trading name is an alternative name to match on.'
    FROM RAW.COMPANIES_OFFICE
    UNION ALL
    SELECT 'RAW.COMPANIES_OFFICE', 'pct_nonblank_PHYSICAL_ADDRESS',
           ROUND(100 * COUNT_IF(NULLIF(TRIM(PHYSICAL_ADDRESS), '') IS NOT NULL) / NULLIF(COUNT(*), 0), 2), '%',
           'Only address field in this source; needed for address and postcode evidence.'
    FROM RAW.COMPANIES_OFFICE
) c;

-- -----------------------------------------------------------------------------
-- 2) Uniqueness. Question: are the ID columns really unique?
--    For each ID: non-blank values, distinct values, and duplicate rows
--    (= non-blank - distinct). The VALUES list turns each ID into 3 rows so the
--    counts are computed once per ID.
--    Registration numbers are upper-cased first, the same as staging does.
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.DQ_PROFILE (RUN_ID, PROFILED_AT, SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS)
SELECT $RUN_ID, $PROFILED_AT,
       u.SRC,
       u.COL || '_' || m.METRIC,
       CASE m.METRIC
           WHEN 'nonblank' THEN u.NB
           WHEN 'distinct' THEN u.D
           ELSE u.NB - u.D
       END,
       'values',
       u.WHY
FROM (
    SELECT 'RAW.CHARITIES_ORGANISATIONS' AS SRC, 'ORGANISATIONID' AS COL,
           COUNT(NULLIF(TRIM(ORGANISATIONID), '')) AS NB,
           COUNT(DISTINCT NULLIF(TRIM(ORGANISATIONID), '')) AS D,
           'Primary key of the charities source; any duplicate breaks RECORD_KEY.' AS WHY
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'CHARITYREGISTRATIONNUMBER',
           COUNT(UPPER(NULLIF(TRIM(CHARITYREGISTRATIONNUMBER), ''))),
           COUNT(DISTINCT UPPER(NULLIF(TRIM(CHARITYREGISTRATIONNUMBER), ''))),
           'Should be one per charity; duplicates would mean re-registrations or copies.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'NZBNNUMBER',
           COUNT(NULLIF(TRIM(NZBNNUMBER), '')),
           COUNT(DISTINCT NULLIF(TRIM(NZBNNUMBER), '')),
           'Several charity records with one NZBN are likely the same legal entity.'
    FROM RAW.CHARITIES_ORGANISATIONS
    UNION ALL
    SELECT 'RAW.COMPANIES_OFFICE', 'NZBN',
           COUNT(NULLIF(TRIM(NZBN), '')),
           COUNT(DISTINCT NULLIF(TRIM(NZBN), '')),
           'Duplicates come from the two overlapping exports; staging keeps one row per NZBN.'
    FROM RAW.COMPANIES_OFFICE
) u
CROSS JOIN (VALUES ('nonblank'), ('distinct'), ('duplicate_rows')) AS m(METRIC);

-- -----------------------------------------------------------------------------
-- 3) Duplicate signals. Question: are there duplicate charities in the register?
--    Exact-name duplicates are a LOWER bound: fuzzy matching will find more.
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.DQ_PROFILE (RUN_ID, PROFILED_AT, SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS)
SELECT $RUN_ID, $PROFILED_AT, c.*
FROM (
    -- NZBN values that appear on more than one charity record.
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'nzbn_shared_by_multiple_records',
           (SELECT COUNT(*) FROM (
                SELECT NULLIF(TRIM(NZBNNUMBER), '') AS NZBN
                FROM RAW.CHARITIES_ORGANISATIONS
                WHERE NZBN IS NOT NULL
                GROUP BY NZBN
                HAVING COUNT(*) > 1)),
           'values',
           'Same NZBN on several records = strong duplicate signal inside the register.'
    UNION ALL
    -- Records whose exact (upper-cased, trimmed) name is used by another record.
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'records_sharing_exact_name',
           (SELECT COALESCE(SUM(N), 0) FROM (
                SELECT UPPER(NULLIF(TRIM(NAME), '')) AS NM, COUNT(*) AS N
                FROM RAW.CHARITIES_ORGANISATIONS
                WHERE NM IS NOT NULL
                GROUP BY NM
                HAVING COUNT(*) > 1)),
           'records',
           'Identical names are duplicate candidates (or common names like "X Parent Teacher Association").'
    UNION ALL
    SELECT 'RAW.CHARITIES_ORGANISATIONS', 'blank_name_records',
           (SELECT COUNT_IF(NULLIF(TRIM(NAME), '') IS NULL) FROM RAW.CHARITIES_ORGANISATIONS),
           'records',
           'Privacy-restricted records: kept for completeness but cannot be matched.'
) c;

-- -----------------------------------------------------------------------------
-- 4) Format issues (charities). Question: which raw values need cleaning rules?
--    Measured on RAW values, BEFORE cleaning, to show the size of each problem.
-- -----------------------------------------------------------------------------
--    All counts are computed in ONE pass over the table (a), then the VALUES
--    list turns them into one row per check (same pattern as section 2).
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.DQ_PROFILE (RUN_ID, PROFILED_AT, SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS)
SELECT $RUN_ID, $PROFILED_AT,
       'RAW.CHARITIES_ORGANISATIONS',
       m.CHECK_NAME,
       CASE m.CHECK_NAME
           WHEN 'reg_no_not_CC_digits'         THEN a.REG_NOT_CC
           WHEN 'reg_no_group_member'          THEN a.REG_GROUP_MEMBER
           WHEN 'phone_multi_number_or_ext'    THEN a.PHONE_MULTI
           WHEN 'phone_intl_nz_prefix'         THEN a.PHONE_INTL_NZ
           WHEN 'phone_overseas'               THEN a.PHONE_OVERSEAS
           WHEN 'street_postcode_not_4_digits' THEN a.SPC_NOT_4
           WHEN 'street_postcode_3_digits'     THEN a.SPC_3
           WHEN 'postal_postcode_not_4_digits' THEN a.PPC_NOT_4
       END,
       'records',
       m.WHY
FROM (
    SELECT
        -- Standard numbers are 'CC' + digits. Anything else (mostly group
        -- members like CC11026-1) needs a rule before it can be compared.
        COUNT_IF(REG IS NOT NULL AND NOT REGEXP_LIKE(REG, '^CC[0-9]+$'))      AS REG_NOT_CC,
        -- Subset of the above: group members, CC<parent>-<n>.
        COUNT_IF(REGEXP_LIKE(REG, '^CC[0-9]+-[0-9]+$'))                       AS REG_GROUP_MEMBER,
        -- Two numbers or an extension in one field. Upper bound: '/' is
        -- sometimes inside ONE number ('06/8710793' = area code + number).
        COUNT_IF(CONTAINS(TEL, '/') OR CONTAINS(TEL, ',')
                 OR CONTAINS(LOWER(TEL), ' or ') OR CONTAINS(LOWER(TEL), 'ext')) AS PHONE_MULTI,
        -- NZ numbers written in international form; must become local 0... form
        -- or they will never equal the same number written locally.
        COUNT_IF(STARTSWITH(TEL, '+64') OR STARTSWITH(TEL, '0064'))           AS PHONE_INTL_NZ,
        -- Same UDF as the OVERSEAS_PHONE flag in staging, so the counts agree.
        COUNT_IF(STAGING.FN_PHONE_IS_OVERSEAS(TEL))                           AS PHONE_OVERSEAS,
        COUNT_IF(SPC IS NOT NULL AND NOT REGEXP_LIKE(SPC, '^[0-9]{4}$'))      AS SPC_NOT_4,
        -- 3 digits = leading zero lost in a spreadsheet (0110-0999); staging
        -- pads these back, so they are recoverable, unlike other bad values.
        COUNT_IF(REGEXP_LIKE(SPC, '^[0-9]{3}$'))                              AS SPC_3,
        COUNT_IF(PPC IS NOT NULL AND NOT REGEXP_LIKE(PPC, '^[0-9]{4}$'))      AS PPC_NOT_4
    FROM (
        SELECT
            UPPER(NULLIF(TRIM(CHARITYREGISTRATIONNUMBER), '')) AS REG,
            NULLIF(TRIM(TELEPHONE1), '')                       AS TEL,
            NULLIF(TRIM(STREETADDRESSPOSTCODE), '')            AS SPC,
            NULLIF(TRIM(POSTALADDRESSPOSTCODE), '')            AS PPC
        FROM RAW.CHARITIES_ORGANISATIONS
    )
) a
CROSS JOIN (VALUES
    ('reg_no_not_CC_digits',         'Reg numbers not in CC+digits form; need a rule before comparing.'),
    ('reg_no_group_member',          'Group members (CC11026-1) can be linked to their parent charity.'),
    ('phone_multi_number_or_ext',    'Joining digits of two numbers creates a phone that matches nothing.'),
    ('phone_intl_nz_prefix',         '+64/0064 numbers must be converted to 0... to match local numbers.'),
    ('phone_overseas',               'Overseas numbers cannot be compared with NZ numbers.'),
    ('street_postcode_not_4_digits', 'NZ postcodes are 4 digits; bad postcodes weaken blocking and address evidence.'),
    ('street_postcode_3_digits',     'Leading zero lost (Northland/Auckland); recoverable by padding.'),
    ('postal_postcode_not_4_digits', 'Postal postcode is the fallback when there is no street address.')
) AS m(CHECK_NAME, WHY);

-- -----------------------------------------------------------------------------
-- 5) Companies Office specifics. Question: what does this source look like?
--    Counted on RAW rows, so the overlapping exports are included.
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.DQ_PROFILE (RUN_ID, PROFILED_AT, SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS)
SELECT $RUN_ID, $PROFILED_AT, c.*
FROM (
    SELECT 'RAW.COMPANIES_OFFICE', 'no_business_name',
           COUNT_IF(NULLIF(TRIM(BUSINESS_NAME), '') IS NULL), 'rows (raw, incl. overlap)',
           'Sole traders: only a trading name, which staging uses as the name.'
    FROM RAW.COMPANIES_OFFICE
    UNION ALL
    SELECT 'RAW.COMPANIES_OFFICE', 'no_physical_address',
           COUNT_IF(NULLIF(TRIM(PHYSICAL_ADDRESS), '') IS NULL), 'rows (raw, incl. overlap)',
           'No address = no postcode block and no address evidence for these records.'
    FROM RAW.COMPANIES_OFFICE
    UNION ALL
    -- One row per entity type: tells us how many are charity-like (trusts,
    -- incorporated societies) versus ordinary companies.
    SELECT 'RAW.COMPANIES_OFFICE',
           'entity_type=' || COALESCE(NULLIF(TRIM(ENTITY_TYPE), ''), '(blank)'),
           COUNT(*), 'rows (raw, incl. overlap)',
           'Entity mix shows which records are likely to also be registered charities.'
    FROM RAW.COMPANIES_OFFICE
    GROUP BY COALESCE(NULLIF(TRIM(ENTITY_TYPE), ''), '(blank)')
) c;

-- -----------------------------------------------------------------------------
-- 6) Cleaning outcome. Question: what did staging (sql/03) find and do?
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.DQ_PROFILE (RUN_ID, PROFILED_AT, SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS)
SELECT $RUN_ID, $PROFILED_AT, c.*
FROM (
    -- One row per DQ flag and source (a record can have several flags).
    SELECT 'STAGING.' || s.SOURCE_SYSTEM,
           'dq_flag=' || f.VALUE::VARCHAR,
           COUNT(*), 'records',
           CASE f.VALUE::VARCHAR
               WHEN 'RESTRICTED_OR_NO_NAME' THEN 'No usable name: kept but IS_MATCHABLE = FALSE.'
               WHEN 'INVALID_POSTCODE'      THEN 'Postcode present but not 4 digits: not used for blocking.'
               WHEN 'OVERSEAS_PHONE'        THEN 'Overseas number: kept out of phone comparison.'
               WHEN 'INVALID_PHONE'         THEN 'Phone present but unusable after cleaning.'
               WHEN 'INVALID_NZBN'          THEN 'NZBN present but not 13 digits: not used as an ID.'
               WHEN 'MISSING_NZBN'          THEN 'No NZBN: record can only match on names/contacts.'
               WHEN 'INVALID_DATE'          THEN 'Registration date could not be parsed.'
               WHEN 'ADDRESS_FROM_POSTAL'   THEN 'No street address; postal address used instead.'
               WHEN 'NAME_FROM_TRADING_AS'  THEN 'Sole trader: trading name used as the main name.'
               ELSE 'See sql/03_standardisation.sql for this flag.'
           END
    FROM STAGING.ORGANISATION_STD s,
         LATERAL FLATTEN(INPUT => s.DQ_FLAGS) f
    GROUP BY s.SOURCE_SYSTEM, f.VALUE::VARCHAR
    UNION ALL
    SELECT 'STAGING.' || SOURCE_SYSTEM, 'not_matchable',
           COUNT_IF(NOT IS_MATCHABLE), 'records',
           'Records excluded from candidate pairs because they have no usable name.'
    FROM STAGING.ORGANISATION_STD
    GROUP BY SOURCE_SYSTEM
    UNION ALL
    -- Denominator = charities WITH an email, not all charities.
    SELECT 'STAGING.CHARITIES_REGISTER', 'pct_generic_email_domain',
           ROUND(100 * COUNT_IF(IS_GENERIC_EMAIL_DOMAIN) / NULLIF(COUNT(*), 0), 2), '% of records with email',
           'Free-mail/trustee-company domains are shared by unrelated charities: not match evidence.'
    FROM STAGING.ORGANISATION_STD
    WHERE SOURCE_SYSTEM = 'CHARITIES_REGISTER'
      AND EMAIL_CLEAN IS NOT NULL
) c;

-- Evidence that shared admin/accountant emails exist: the 10 non-generic emails
-- used by the most records. SOURCE holds the email itself. Kept in its own
-- INSERT because ORDER BY + LIMIT cannot sit inside a UNION ALL branch.
-- Note: these are real email addresses; check before quoting them in docs.
INSERT INTO AUDIT.DQ_PROFILE (RUN_ID, PROFILED_AT, SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS)
SELECT $RUN_ID, $PROFILED_AT,
       t.EMAIL_CLEAN, 'shared_email_record_count', t.N, 'records',
       'One email on many records = shared administrator/accountant, not the same organisation.'
FROM (
    SELECT EMAIL_CLEAN, COUNT(*) AS N
    FROM STAGING.ORGANISATION_STD
    WHERE EMAIL_CLEAN IS NOT NULL
      AND NOT IS_GENERIC_EMAIL_DOMAIN
    GROUP BY EMAIL_CLEAN
    HAVING COUNT(*) > 1
    ORDER BY N DESC, EMAIL_CLEAN
    LIMIT 10
) t;

-- -----------------------------------------------------------------------------
-- 7) Results of this run (last, so this is what you see in Snowsight).
-- -----------------------------------------------------------------------------
SELECT SOURCE, CHECK_NAME, METRIC_VALUE, UNIT, WHY_IT_MATTERS
FROM AUDIT.DQ_PROFILE
WHERE RUN_ID = $RUN_ID
ORDER BY SOURCE, CHECK_NAME;
