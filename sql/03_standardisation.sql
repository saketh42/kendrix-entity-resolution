-- =============================================================================
-- 03_standardisation.sql
-- Purpose : Clean and standardise both sources into ONE table with the same
--           columns, so later steps can compare names, addresses, phones,
--           emails and IDs like-for-like.
-- Owner   : Data Engineer (Shubham)
-- Inputs  : RAW.CHARITIES_ORGANISATIONS (46,045 rows)
--           RAW.COMPANIES_OFFICE        (2,000 rows, 1,664 unique NZBN)
-- Outputs : STAGING.FN_NAME_CLEAN, STAGING.FN_NAME_CORE,
--           STAGING.FN_PLACE_CLEAN, STAGING.FN_ADDRESS_CLEAN,
--           STAGING.FN_PHONE_IS_OVERSEAS, STAGING.FN_PHONE_CLEAN (SQL UDFs)
--           STAGING.ORGANISATION_STD - one row per source record
--           one row in AUDIT.PIPELINE_RUN (step '03_standardisation')
-- Notes   : Idempotent (CREATE OR REPLACE). Rule version 'std_v1'.
--           RAW is all VARCHAR and the source CSV quotes every field, so blanks
--           are '' not NULL. Every source column goes through NULLIF(TRIM(col), '')
--           first, otherwise blank phones/emails would "match" each other.
--           The name/address rules live in UDFs so the same logic is used for
--           every name column and can be unit-tested in
--           tests/sql/test_standardisation.sql.
--           Regex literals avoid backslashes ([.] instead of \\.) so there is no
--           escaping ambiguity inside the $$ function bodies. The one exception
--           is the back-reference '\\1' in FN_PHONE_CLEAN (= \1 in the regex).
-- =============================================================================

USE DATABASE KENDRIX;

-- One RUN_ID for this run, shared by every row and the audit log entry.
-- SET only accepts constants or subqueries, so function calls are wrapped in (SELECT ...).
SET RUN_ID = (SELECT UUID_STRING());
SET STARTED_AT = (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

-- -----------------------------------------------------------------------------
-- 1) Name cleaning. Steps, innermost first:
--    a. TRANSLATE macrons to plain vowels: 'Ngāti' and 'Ngati' are both common
--       spellings of the same name, so they must compare equal.
--    b. UPPER: case carries no meaning for matching.
--    c. '&' -> ' AND ': 'Smith & Sons' and 'Smith and Sons' are the same name.
--    d. Apostrophes deleted (straight and curly): ST JOHN'S -> ST JOHNS, not
--       'ST JOHN S', which would add a fake one-letter word.
--    e. Any other character outside A-Z, 0-9, space -> space: punctuation and
--       line breaks are formatting noise ('St. John' = 'St John').
--    f. Collapse repeated whitespace and TRIM.
--    g. Whole-word LIMITED->LTD, INCORPORATED->INC, COMPANY->CO: sources mix the
--       long and short legal forms. Padding with spaces and replacing ' WORD '
--       gives whole-word matching without relying on regex word boundaries.
--    h. Strip one leading 'THE TRUSTEES OF THE ' / 'TRUSTEES OF THE ' /
--       'TRUSTEES IN THE ' / 'THE ' (longest first): charities are often
--       registered as 'The Trustees of the X Trust' but known as 'X Trust'.
--    i. NULLIF(.., ''): a name that cleans to nothing is treated as no name.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION STAGING.FN_NAME_CLEAN(S VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    NULLIF(
        REGEXP_REPLACE(                                                        /* h */
            TRIM(
                REPLACE(REPLACE(REPLACE(                                       /* g */
                    ' ' || TRIM(REGEXP_REPLACE(                                /* f */
                        REGEXP_REPLACE(                                        /* e */
                            REPLACE(REPLACE(                                   /* d */
                                REPLACE(                                       /* c */
                                    UPPER(                                     /* b */
                                        TRANSLATE(S, 'āēīōūĀĒĪŌŪ', 'aeiouAEIOU')  /* a */
                                    ),
                                '&', ' AND '),
                            '''', ''), '’', ''),
                        '[^A-Z0-9 ]', ' '),
                    '[[:space:]]+', ' ')) || ' ',
                ' LIMITED ', ' LTD '), ' INCORPORATED ', ' INC '), ' COMPANY ', ' CO ')
            ),
        '^(THE TRUSTEES OF THE|TRUSTEES OF THE|TRUSTEES IN THE|THE) ', ''),
    '')                                                                        /* i */
$$;

-- -----------------------------------------------------------------------------
-- 2) Name core, for fuzzy comparison. Input is a NAME_CLEAN value.
--    Removes trailing legal-form words (CHARITABLE TRUST, TRUST BOARD, TRUST,
--    INC, LTD, INCORPORATED SOCIETY / INC SOCIETY, SOCIETY): 'X Trust' and
--    'X Charitable Trust' are usually the same organisation, and the legal form
--    words would otherwise inflate fuzzy similarity between unrelated names.
--    FOUNDATION is deliberately kept: it is usually part of the real name.
--    Applied twice so stacked endings like 'SOCIETY INC' or 'TRUST LTD' go too.
--    The pattern needs a leading space, so a one-word name is never emptied;
--    COALESCE is a final safety net back to the input.
--    ('INC SOCIETY' is listed because NAME_CLEAN has already shortened
--    INCORPORATED to INC.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION STAGING.FN_NAME_CORE(S VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    COALESCE(
        NULLIF(
            REGEXP_REPLACE(
                REGEXP_REPLACE(S,
                    ' (CHARITABLE TRUST|TRUST BOARD|INCORPORATED SOCIETY|INC SOCIETY|TRUST|INC|LTD|SOCIETY)$', ''),
                ' (CHARITABLE TRUST|TRUST BOARD|INCORPORATED SOCIETY|INC SOCIETY|TRUST|INC|LTD|SOCIETY)$', ''),
        ''),
    S)
$$;

-- -----------------------------------------------------------------------------
-- 3) Place cleaning, used for SUBURB and CITY: macrons to plain vowels (so
--    'Ōtaki' = 'OTAKI'), UPPER, collapse whitespace, TRIM, '' -> NULL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION STAGING.FN_PLACE_CLEAN(S VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    NULLIF(
        TRIM(REGEXP_REPLACE(UPPER(TRANSLATE(S, 'āēīōūĀĒĪŌŪ', 'aeiouAEIOU')), '[[:space:]]+', ' ')),
    '')
$$;

-- -----------------------------------------------------------------------------
-- 4) Address line cleaning: place cleaning, plus
--    - punctuation -> space, except '/' and '-' which carry meaning in NZ
--      addresses (unit '2/15', range '12-14'), so '23 High St.' = '23 High St';
--    - whole-word street types shortened (STREET->ST, ROAD->RD, AVENUE->AVE,
--      DRIVE->DR, PLACE->PL, CRESCENT->CRES, TERRACE->TCE), because sources mix
--      long and short forms. Same pad-with-spaces trick as the name rules.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION STAGING.FN_ADDRESS_CLEAN(S VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    NULLIF(
        TRIM(
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                ' ' || STAGING.FN_PLACE_CLEAN(
                    REGEXP_REPLACE(UPPER(TRANSLATE(S, 'āēīōūĀĒĪŌŪ', 'aeiouAEIOU')), '[^A-Z0-9/ -]', ' ')
                ) || ' ',
            ' STREET ', ' ST '), ' ROAD ', ' RD '), ' AVENUE ', ' AVE '), ' DRIVE ', ' DR '),
            ' PLACE ', ' PL '), ' CRESCENT ', ' CRES '), ' TERRACE ', ' TCE ')
        ),
    '')
$$;

-- -----------------------------------------------------------------------------
-- 4b) Phone: overseas check (step 4 of the phone rule, used by FN_PHONE_CLEAN
--     and by the OVERSEAS_PHONE flag). A number written with '+' and a country
--     code other than 64 (e.g. +61, +44, +1) is not an NZ number and cannot be
--     compared with NZ numbers. [^0-9]* allows '+ 64' or '+(64)'.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION STAGING.FN_PHONE_IS_OVERSEAS(S VARCHAR)
RETURNS BOOLEAN
LANGUAGE SQL
AS
$$
    COALESCE(
        REGEXP_LIKE(TRIM(S), '^[+].*$', 's')
        AND NOT REGEXP_LIKE(TRIM(S), '^[+][^0-9]*64.*$', 's'),
    FALSE)
$$;

-- -----------------------------------------------------------------------------
-- 4c) Phone cleaning. Steps, innermost first:
--    1a. Keep only the FIRST number: cut the text at ',', ' or ', '&', 'ext'
--        (also covers 'extn'), ' ex ', ' x '. Fields often hold a second number
--        or an extension ('094807365, extn 5', '06-3758385 or 027'); joining
--        their digits would create a number that matches nothing.
--        Lower-cased first so 'OR' / 'Ext' are cut too.
--    1b. Cut at '/' ONLY when the part before it already has 7+ digits: then
--        '/' separates two numbers ('098373727/0211449638' keeps the first).
--        With fewer digits the '/' is inside one number ('06/8710793' = area
--        code + number), so it is kept whole.
--    2.  Digits only: '(04) 123-4567' = '041234567'.
--    3.  International NZ format: remove a leading 0064 or 64, then any leading
--        zeros, then add one '0' ('+64 021 1325689', '+64 (0)21 ...' and
--        '0064 21 ...' all become '021...'). Local numbers are unchanged.
--    4.  Overseas numbers -> NULL (see FN_PHONE_IS_OVERSEAS).
--    5.  Valid only if 8 to 11 digits starting with 0 (NZ landline, mobile and
--        0800 lengths); anything else ('N/A', '-', fragments) -> NULL.
--        REGEXP_SUBSTR returns NULL when the pattern does not match.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION STAGING.FN_PHONE_CLEAN(S VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    IFF(STAGING.FN_PHONE_IS_OVERSEAS(S), NULL,                                 /* 4 */
        REGEXP_SUBSTR(                                                         /* 5 */
            REGEXP_REPLACE(                                                    /* 3 */
                REGEXP_REPLACE(                                                /* 2 */
                    REGEXP_REPLACE(                                            /* 1b */
                        REGEXP_REPLACE(LOWER(S), '(,| or |&|ext| ex | x ).*$', '', 1, 1, 's'),  /* 1a */
                    '^(([^0-9/]*[0-9]){7}[^/]*)/.*$', '\\1', 1, 1, 's'),
                '[^0-9]', ''),
            '^(0064|64)0*', '0'),
        '^0[0-9]{7,10}$')
    )
$$;

-- -----------------------------------------------------------------------------
-- 5) STAGING.ORGANISATION_STD: one row per source record, same columns for
--    every source. Each source is mapped to a common shape in its own CTEs,
--    then the shared cleaning rules are applied ONCE to the union.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE STAGING.ORGANISATION_STD AS
WITH
-- Charities: blanks ('') -> NULL for every column we use.
chr_src AS (
    SELECT
        NULLIF(TRIM(ORGANISATIONID), '')            AS ORGANISATIONID,
        NULLIF(TRIM(NAME), '')                      AS NAME,
        NULLIF(TRIM(OTHERNAMES), '')                AS OTHERNAMES,
        UPPER(NULLIF(TRIM(CHARITYREGISTRATIONNUMBER), '')) AS CHARITYREGISTRATIONNUMBER,
        NULLIF(TRIM(NZBNNUMBER), '')                AS NZBNNUMBER,
        NULLIF(TRIM(COMPANIESOFFICENUMBER), '')     AS COMPANIESOFFICENUMBER,
        NULLIF(TRIM(EMAILADDRESS1), '')             AS EMAILADDRESS1,
        NULLIF(TRIM(CHARITYEMAILADDRESS), '')       AS CHARITYEMAILADDRESS,
        NULLIF(TRIM(TELEPHONE1), '')                AS TELEPHONE1,
        NULLIF(TRIM(WEBSITEURL), '')                AS WEBSITEURL,
        NULLIF(TRIM(STREETADDRESSLINE1), '')        AS STREETADDRESSLINE1,
        NULLIF(TRIM(STREETADDRESSLINE2), '')        AS STREETADDRESSLINE2,
        NULLIF(TRIM(STREETADDRESSSUBURB), '')       AS STREETADDRESSSUBURB,
        NULLIF(TRIM(STREETADDRESSCITY), '')         AS STREETADDRESSCITY,
        NULLIF(TRIM(STREETADDRESSPOSTCODE), '')     AS STREETADDRESSPOSTCODE,
        NULLIF(TRIM(POSTALADDRESSLINE1), '')        AS POSTALADDRESSLINE1,
        NULLIF(TRIM(POSTALADDRESSLINE2), '')        AS POSTALADDRESSLINE2,
        NULLIF(TRIM(POSTALADDRESSSUBURB), '')       AS POSTALADDRESSSUBURB,
        NULLIF(TRIM(POSTALADDRESSCITY), '')         AS POSTALADDRESSCITY,
        NULLIF(TRIM(POSTALADDRESSPOSTCODE), '')     AS POSTALADDRESSPOSTCODE,
        NULLIF(TRIM(REGISTRATIONSTATUS), '')        AS REGISTRATIONSTATUS,
        NULLIF(TRIM(DATEREGISTERED), '')            AS DATEREGISTERED
    FROM RAW.CHARITIES_ORGANISATIONS
),

-- Charities mapped to the common shape.
chr_std AS (
    SELECT
        'CHR:' || ORGANISATIONID                    AS RECORD_KEY,
        'CHARITIES_REGISTER'                        AS SOURCE_SYSTEM,
        ORGANISATIONID                              AS SOURCE_RECORD_ID,
        NAME                                        AS NAME_RAW,
        NAME                                        AS NAME_INPUT,
        OTHERNAMES                                  AS ALT_NAME_1,
        NULL::VARCHAR                               AS ALT_NAME_2,
        CHARITYREGISTRATIONNUMBER                   AS CHARITY_REG_NO,
        -- Group members are numbered like CC11026-1; the part before '-' is the
        -- parent charity, which lets group members be linked to their parent.
        SPLIT_PART(CHARITYREGISTRATIONNUMBER, '-', 1) AS CHARITY_PARENT_REG_NO,
        NZBNNUMBER                                  AS NZBN_RAW,
        COMPANIESOFFICENUMBER                       AS COMPANY_NO,
        -- Prefer the street address (physical location = best match evidence).
        -- Only when STREETADDRESSLINE1 is blank, take the WHOLE postal block, so
        -- line, suburb, city and postcode never come from two different addresses.
        -- LINE1 + LINE2 are joined with ARRAY_CONSTRUCT_COMPACT because CONCAT_WS
        -- returns NULL if any part is NULL.
        IFF(STREETADDRESSLINE1 IS NOT NULL,
            ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(STREETADDRESSLINE1, STREETADDRESSLINE2), ' '),
            ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(POSTALADDRESSLINE1, POSTALADDRESSLINE2), ' ')
        )                                           AS ADDRESS_LINE_RAW,
        IFF(STREETADDRESSLINE1 IS NOT NULL, STREETADDRESSSUBURB,   POSTALADDRESSSUBURB)   AS SUBURB_RAW,
        IFF(STREETADDRESSLINE1 IS NOT NULL, STREETADDRESSCITY,     POSTALADDRESSCITY)     AS CITY_RAW,
        IFF(STREETADDRESSLINE1 IS NOT NULL, STREETADDRESSPOSTCODE, POSTALADDRESSPOSTCODE) AS POSTCODE_RAW,
        TELEPHONE1                                  AS PHONE_RAW,
        -- EMAILADDRESS1 is the main contact; CHARITYEMAILADDRESS fills gaps.
        COALESCE(EMAILADDRESS1, CHARITYEMAILADDRESS) AS EMAIL_RAW,
        WEBSITEURL                                  AS WEBSITE_RAW,
        UPPER(REGISTRATIONSTATUS)                   AS ENTITY_STATUS,
        DATEREGISTERED                              AS REGISTERED_DATE_RAW,
        -- Charities dates are DD/MM/YYYY; SPLIT_PART drops any time part.
        TRY_TO_DATE(SPLIT_PART(DATEREGISTERED, ' ', 1), 'DD/MM/YYYY') AS REGISTERED_DATE,
        -- Flag only when postal data was actually used (a record with no
        -- address at all is not "from postal").
        ARRAY_CONSTRUCT_COMPACT(
            IFF(STREETADDRESSLINE1 IS NULL AND POSTALADDRESSLINE1 IS NOT NULL, 'ADDRESS_FROM_POSTAL', NULL)
        )                                           AS SOURCE_FLAGS
    FROM chr_src
),

-- Companies Office: blanks -> NULL, then one row per NZBN.
-- The two .xls exports came from two overlapping searches, so the same company
-- appears in both (2,000 rows but only 1,664 NZBNs). Keep the first export's
-- copy; BUSINESS_NAME is a tiebreaker so re-runs always pick the same row.
cos_src AS (
    SELECT
        NULLIF(TRIM(BUSINESS_NAME), '')             AS BUSINESS_NAME,
        NULLIF(TRIM(NZBN), '')                      AS NZBN,
        NULLIF(TRIM(REGISTRATION_DATE), '')         AS REGISTRATION_DATE,
        NULLIF(TRIM(TRADING_AS), '')                AS TRADING_AS,
        NULLIF(TRIM(PHYSICAL_ADDRESS), '')          AS PHYSICAL_ADDRESS,
        NULLIF(TRIM(PREVIOUSLY_KNOWN_AS), '')       AS PREVIOUSLY_KNOWN_AS,
        NULLIF(TRIM(STATUS), '')                    AS STATUS,
        NULLIF(TRIM(EXPORT_FILE), '')               AS EXPORT_FILE
    FROM RAW.COMPANIES_OFFICE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY NULLIF(TRIM(NZBN), '')
                               ORDER BY EXPORT_FILE, BUSINESS_NAME) = 1
),

-- PHYSICAL_ADDRESS is one string like
-- '23 HIGH STREET, ISLAND BAY, WELLINGTON, 6012, New Zealand'.
-- Split it into parts and drop the trailing country: every record is in NZ.
cos_addr_split AS (
    SELECT
        c.*,
        SPLIT(c.PHYSICAL_ADDRESS, ', ')             AS PARTS_ALL
    FROM cos_src c
),
cos_addr_parts AS (
    SELECT
        s.*,
        IFF(UPPER(TRIM(GET(s.PARTS_ALL, ARRAY_SIZE(s.PARTS_ALL) - 1)::VARCHAR)) = 'NEW ZEALAND',
            ARRAY_SLICE(s.PARTS_ALL, 0, ARRAY_SIZE(s.PARTS_ALL) - 1),
            s.PARTS_ALL)                            AS PARTS
    FROM cos_addr_split s
),
-- Work from the right. If the last part is all digits it is the postcode
-- (validated to 4 digits later, so a bad postcode is flagged, not mistaken for
-- a city). K = number of parts left once the postcode is removed.
cos_addr_pc AS (
    SELECT
        p.*,
        ARRAY_SIZE(p.PARTS)                         AS N,
        REGEXP_LIKE(TRIM(GET(p.PARTS, ARRAY_SIZE(p.PARTS) - 1)::VARCHAR), '^[0-9]+$') AS HAS_PC,
        ARRAY_SIZE(p.PARTS) - IFF(HAS_PC, 1, 0)     AS K
    FROM cos_addr_parts p
),

-- Companies Office mapped to the common shape.
-- From the right: CITY = last non-postcode part, SUBURB = the part before it
-- when at least 3 parts remain (otherwise there is no suburb, just line + city),
-- ADDRESS_LINE = everything before that.
cos_std AS (
    SELECT
        'COS:' || NZBN                              AS RECORD_KEY,
        'COMPANIES_OFFICE'                          AS SOURCE_SYSTEM,
        NZBN                                        AS SOURCE_RECORD_ID,
        -- Sole traders have no BUSINESS_NAME, only a trading name; use it so
        -- they can still be matched (flagged below).
        COALESCE(BUSINESS_NAME, TRADING_AS)         AS NAME_RAW,
        COALESCE(BUSINESS_NAME, TRADING_AS)         AS NAME_INPUT,
        -- Trading name is an alternative name, unless it was already used as
        -- the main name (then it would just duplicate NAME_CLEAN).
        IFF(BUSINESS_NAME IS NULL, NULL, TRADING_AS) AS ALT_NAME_1,
        PREVIOUSLY_KNOWN_AS                         AS ALT_NAME_2,
        NULL::VARCHAR                               AS CHARITY_REG_NO,
        NULL::VARCHAR                               AS CHARITY_PARENT_REG_NO,
        NZBN                                        AS NZBN_RAW,
        NULL::VARCHAR                               AS COMPANY_NO,
        IFF(K >= 1,
            ARRAY_TO_STRING(ARRAY_SLICE(PARTS, 0, GREATEST(IFF(K >= 3, K - 2, K - 1), 0)), ' '),
            NULL)                                   AS ADDRESS_LINE_RAW,
        IFF(K >= 3, TRIM(GET(PARTS, K - 2)::VARCHAR), NULL) AS SUBURB_RAW,
        IFF(K >= 1, TRIM(GET(PARTS, K - 1)::VARCHAR), NULL) AS CITY_RAW,
        IFF(HAS_PC, TRIM(GET(PARTS, N - 1)::VARCHAR), NULL) AS POSTCODE_RAW,
        NULL::VARCHAR                               AS PHONE_RAW,
        NULL::VARCHAR                               AS EMAIL_RAW,
        NULL::VARCHAR                               AS WEBSITE_RAW,
        UPPER(STATUS)                               AS ENTITY_STATUS,
        REGISTRATION_DATE                           AS REGISTERED_DATE_RAW,
        -- Companies Office dates look like 30-May-2006.
        TRY_TO_DATE(REGISTRATION_DATE, 'DD-MON-YYYY') AS REGISTERED_DATE,
        ARRAY_CONSTRUCT_COMPACT(
            IFF(BUSINESS_NAME IS NULL AND TRADING_AS IS NOT NULL, 'NAME_FROM_TRADING_AS', NULL)
        )                                           AS SOURCE_FLAGS
    FROM cos_addr_pc
),

unioned AS (
    SELECT * FROM chr_std
    UNION ALL
    SELECT * FROM cos_std
),

-- Shared cleaning rules, applied once to both sources.
cleaned AS (
    SELECT
        u.*,
        STAGING.FN_NAME_CLEAN(u.NAME_INPUT)         AS NAME_CLEAN,
        STAGING.FN_NAME_CORE(STAGING.FN_NAME_CLEAN(u.NAME_INPUT)) AS NAME_CORE,
        -- Alternative names use exactly the same cleaning as the main name so
        -- they can be compared against NAME_CLEAN of other records.
        ARRAY_CONSTRUCT_COMPACT(STAGING.FN_NAME_CLEAN(u.ALT_NAME_1),
                                STAGING.FN_NAME_CLEAN(u.ALT_NAME_2)) AS ALT_NAMES,
        STAGING.FN_ADDRESS_CLEAN(u.ADDRESS_LINE_RAW) AS ADDRESS_LINE_CLEAN,
        STAGING.FN_PLACE_CLEAN(u.SUBURB_RAW)        AS SUBURB,
        STAGING.FN_PLACE_CLEAN(u.CITY_RAW)          AS CITY,
        -- NZ postcodes are 4 digits. Postcodes 0110-0999 (Northland/Auckland)
        -- often lose their leading zero in spreadsheets, so a 3-digit value is
        -- padded back; anything else that is not 4 digits is invalid.
        CASE
            WHEN REGEXP_LIKE(u.POSTCODE_RAW, '^[0-9]{4}$') THEN u.POSTCODE_RAW
            WHEN REGEXP_LIKE(u.POSTCODE_RAW, '^[0-9]{3}$') THEN LPAD(u.POSTCODE_RAW, 4, '0')
        END                                         AS POSTCODE,
        -- Phone: first NZ number only, in local 0... form (rules in 4b/4c).
        STAGING.FN_PHONE_CLEAN(u.PHONE_RAW)         AS PHONE_CLEAN,
        STAGING.FN_PHONE_IS_OVERSEAS(u.PHONE_RAW)   AS IS_OVERSEAS_PHONE,
        -- Emails are case-insensitive in practice.
        LOWER(u.EMAIL_RAW)                          AS EMAIL_CLEAN,
        NULLIF(SPLIT_PART(EMAIL_CLEAN, '@', 2), '') AS EMAIL_DOMAIN,
        -- Free-mail and shared trustee-company domains are used by many
        -- unrelated charities, so a shared domain there is NOT match evidence.
        COALESCE(EMAIL_DOMAIN IN ('gmail.com', 'xtra.co.nz', 'hotmail.com', 'outlook.com',
                                  'yahoo.com', 'yahoo.co.nz', 'icloud.com', 'live.com',
                                  'pgtrust.co.nz', 'publictrust.co.nz'), FALSE)
                                                    AS IS_GENERIC_EMAIL_DOMAIN,
        -- Website: keep only the host, so 'https://www.x.org.nz/about' = 'x.org.nz'.
        NULLIF(SPLIT_PART(
            REGEXP_REPLACE(REGEXP_REPLACE(LOWER(u.WEBSITE_RAW), '^https?://', ''), '^www[.]', ''),
            '/', 1), '')                            AS WEBSITE_DOMAIN,
        -- NZBN is always 13 digits; spaces are removed first because numbers are
        -- sometimes typed in groups. Anything else is unusable as an ID.
        IFF(REGEXP_LIKE(REPLACE(u.NZBN_RAW, ' ', ''), '^[0-9]{13}$'),
            REPLACE(u.NZBN_RAW, ' ', ''), NULL)     AS NZBN
    FROM unioned u
)

SELECT
    RECORD_KEY::VARCHAR                             AS RECORD_KEY,
    SOURCE_SYSTEM::VARCHAR                          AS SOURCE_SYSTEM,
    SOURCE_RECORD_ID::VARCHAR                       AS SOURCE_RECORD_ID,
    NAME_RAW::VARCHAR                               AS NAME_RAW,
    NAME_CLEAN::VARCHAR                             AS NAME_CLEAN,
    NAME_CORE::VARCHAR                              AS NAME_CORE,
    ALT_NAMES::ARRAY                                AS ALT_NAMES,
    CHARITY_REG_NO::VARCHAR                         AS CHARITY_REG_NO,
    CHARITY_PARENT_REG_NO::VARCHAR                  AS CHARITY_PARENT_REG_NO,
    NZBN::VARCHAR                                   AS NZBN,
    COMPANY_NO::VARCHAR                             AS COMPANY_NO,
    ADDRESS_LINE_CLEAN::VARCHAR                     AS ADDRESS_LINE_CLEAN,
    SUBURB::VARCHAR                                 AS SUBURB,
    CITY::VARCHAR                                   AS CITY,
    POSTCODE::VARCHAR                               AS POSTCODE,
    PHONE_CLEAN::VARCHAR                            AS PHONE_CLEAN,
    EMAIL_CLEAN::VARCHAR                            AS EMAIL_CLEAN,
    EMAIL_DOMAIN::VARCHAR                           AS EMAIL_DOMAIN,
    IS_GENERIC_EMAIL_DOMAIN::BOOLEAN                AS IS_GENERIC_EMAIL_DOMAIN,
    WEBSITE_DOMAIN::VARCHAR                         AS WEBSITE_DOMAIN,
    ENTITY_STATUS::VARCHAR                          AS ENTITY_STATUS,
    REGISTERED_DATE::DATE                           AS REGISTERED_DATE,
    -- Records with no usable name (incl. the 4 privacy-restricted charities)
    -- stay here for completeness but are excluded from matching later.
    (NAME_CLEAN IS NOT NULL)::BOOLEAN               AS IS_MATCHABLE,
    -- "INVALID_*" flags only fire when a value existed but failed the rule, so
    -- a blank is never reported as invalid.
    ARRAY_CAT(SOURCE_FLAGS, ARRAY_CONSTRUCT_COMPACT(
        IFF(NAME_CLEAN IS NULL, 'RESTRICTED_OR_NO_NAME', NULL),
        IFF(POSTCODE_RAW IS NOT NULL AND POSTCODE IS NULL, 'INVALID_POSTCODE', NULL),
        -- Overseas numbers get their own flag instead of INVALID_PHONE: the
        -- value is fine, it just cannot be compared with NZ numbers.
        IFF(IS_OVERSEAS_PHONE, 'OVERSEAS_PHONE', NULL),
        IFF(PHONE_RAW IS NOT NULL AND PHONE_CLEAN IS NULL AND NOT IS_OVERSEAS_PHONE, 'INVALID_PHONE', NULL),
        IFF(NZBN_RAW IS NOT NULL AND NZBN IS NULL, 'INVALID_NZBN', NULL),
        IFF(NZBN IS NULL, 'MISSING_NZBN', NULL),
        IFF(REGISTERED_DATE_RAW IS NOT NULL AND REGISTERED_DATE IS NULL, 'INVALID_DATE', NULL)
    ))::ARRAY                                       AS DQ_FLAGS,
    $RUN_ID::VARCHAR                                AS RUN_ID,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ              AS STANDARDISED_AT
FROM cleaned;

-- -----------------------------------------------------------------------------
-- 6) Audit log row. SUCCESS only if both sources have the expected row counts:
--    46,045 charities and 1,664 Companies Office (after NZBN de-duplication).
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.PIPELINE_RUN (RUN_ID, STEP, STARTED_AT, FINISHED_AT, ROWS_OUT, RULE_VERSION, STATUS, NOTES)
SELECT $RUN_ID, '03_standardisation',
       $STARTED_AT,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
       c.n + co.n, 'std_v1',
       IFF(c.n = 46045 AND co.n = 1664, 'SUCCESS', 'FAIL'),
       'charities=' || c.n || ', companies_office=' || co.n
FROM (SELECT COUNT(*) n FROM STAGING.ORGANISATION_STD WHERE SOURCE_SYSTEM = 'CHARITIES_REGISTER') c,
     (SELECT COUNT(*) n FROM STAGING.ORGANISATION_STD WHERE SOURCE_SYSTEM = 'COMPANIES_OFFICE') co;

-- -----------------------------------------------------------------------------
-- 7) Summary (last, so this result is what you see in Snowsight).
-- -----------------------------------------------------------------------------
SELECT
    SOURCE_SYSTEM,
    COUNT(*)                                        AS rows_out,
    COUNT_IF(NOT IS_MATCHABLE)                      AS not_matchable,
    ROUND(100 * COUNT(NZBN)        / COUNT(*), 1)   AS pct_nzbn,
    ROUND(100 * COUNT(POSTCODE)    / COUNT(*), 1)   AS pct_postcode,
    ROUND(100 * COUNT(PHONE_CLEAN) / COUNT(*), 1)   AS pct_phone,
    ROUND(100 * COUNT(EMAIL_CLEAN) / COUNT(*), 1)   AS pct_email
FROM STAGING.ORGANISATION_STD
GROUP BY SOURCE_SYSTEM
ORDER BY SOURCE_SYSTEM;
