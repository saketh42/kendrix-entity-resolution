-- =============================================================================
-- test_standardisation.sql
-- Purpose : Data tests for sql/03_standardisation.sql.
--           Every test returns FAILURE rows: 0 rows = PASS.
--           The last query runs all tests at once and returns
--           test_name + failure_count (all 0 = everything passes).
-- Owner   : Data Engineer (Shubham)
-- Inputs  : STAGING.ORGANISATION_STD, STAGING.FN_NAME_CLEAN, STAGING.FN_NAME_CORE,
--           STAGING.FN_PHONE_CLEAN
-- Outputs : None (read-only queries).
-- =============================================================================

USE DATABASE KENDRIX;

-- Test: duplicate_record_key -- RECORD_KEY must be unique.
SELECT RECORD_KEY, COUNT(*) AS n
FROM STAGING.ORGANISATION_STD
GROUP BY RECORD_KEY
HAVING COUNT(*) > 1;

-- Test: source_row_counts -- 46,045 charities and 1,664 Companies Office rows
-- (after NZBN de-duplication). FULL JOIN also catches a missing or extra source.
SELECT COALESCE(e.SOURCE_SYSTEM, a.SOURCE_SYSTEM) AS SOURCE_SYSTEM,
       e.EXPECTED_ROWS, a.ACTUAL_ROWS
FROM (SELECT * FROM VALUES ('CHARITIES_REGISTER', 46045), ('COMPANIES_OFFICE', 1664)
          AS v(SOURCE_SYSTEM, EXPECTED_ROWS)) e
FULL OUTER JOIN (SELECT SOURCE_SYSTEM, COUNT(*) AS ACTUAL_ROWS
                 FROM STAGING.ORGANISATION_STD GROUP BY SOURCE_SYSTEM) a
  ON e.SOURCE_SYSTEM = a.SOURCE_SYSTEM
WHERE e.EXPECTED_ROWS IS DISTINCT FROM a.ACTUAL_ROWS;

-- Test: matchable_without_name -- a record with no cleaned name must not be matchable.
SELECT RECORD_KEY, NAME_RAW
FROM STAGING.ORGANISATION_STD
WHERE IS_MATCHABLE AND NAME_CLEAN IS NULL;

-- Test: postcode_not_4_digits
SELECT RECORD_KEY, POSTCODE
FROM STAGING.ORGANISATION_STD
WHERE POSTCODE IS NOT NULL AND NOT REGEXP_LIKE(POSTCODE, '^[0-9]{4}$');

-- Test: phone_non_digits
SELECT RECORD_KEY, PHONE_CLEAN
FROM STAGING.ORGANISATION_STD
WHERE PHONE_CLEAN IS NOT NULL AND NOT REGEXP_LIKE(PHONE_CLEAN, '^[0-9]+$');

-- Test: nzbn_not_13_digits
SELECT RECORD_KEY, NZBN
FROM STAGING.ORGANISATION_STD
WHERE NZBN IS NOT NULL AND NOT REGEXP_LIKE(NZBN, '^[0-9]{13}$');

-- Test: empty_strings_left -- blanks must be NULL, otherwise blank values
-- would "match" each other in later steps.
SELECT RECORD_KEY, NZBN, PHONE_CLEAN, EMAIL_CLEAN, POSTCODE
FROM STAGING.ORGANISATION_STD
WHERE NZBN = '' OR PHONE_CLEAN = '' OR EMAIL_CLEAN = '' OR POSTCODE = '';

-- Test: name_rules -- known inputs give the expected NAME_CLEAN and NAME_CORE,
-- using the same UDFs the pipeline uses.
SELECT t.INPUT_NAME, t.EXPECTED_CLEAN, t.EXPECTED_CORE,
       STAGING.FN_NAME_CLEAN(t.INPUT_NAME)                        AS ACTUAL_CLEAN,
       STAGING.FN_NAME_CORE(STAGING.FN_NAME_CLEAN(t.INPUT_NAME))  AS ACTUAL_CORE
FROM VALUES
    ('The Trustees of the Hocken Library Trust', 'HOCKEN LIBRARY TRUST',    'HOCKEN LIBRARY'),
    ('Music Futures Incorporated',               'MUSIC FUTURES INC',       'MUSIC FUTURES'),
    ('Ngāti Awa Farms Limited',                  'NGATI AWA FARMS LTD',     'NGATI AWA FARMS'),
    ('Smith & Sons Company Limited',             'SMITH AND SONS CO LTD',   'SMITH AND SONS CO'),
    ('St. John''s Foundation',                   'ST JOHNS FOUNDATION',     'ST JOHNS FOUNDATION'),
    ('Otago Rugby Society Incorporated',         'OTAGO RUGBY SOCIETY INC', 'OTAGO RUGBY')
    AS t(INPUT_NAME, EXPECTED_CLEAN, EXPECTED_CORE)
WHERE STAGING.FN_NAME_CLEAN(t.INPUT_NAME) IS DISTINCT FROM t.EXPECTED_CLEAN
   OR STAGING.FN_NAME_CORE(STAGING.FN_NAME_CLEAN(t.INPUT_NAME)) IS DISTINCT FROM t.EXPECTED_CORE;

-- Test: phone_rules -- real phone patterns give the expected PHONE_CLEAN,
-- using the same UDF the pipeline uses.
SELECT t.INPUT_PHONE, t.EXPECTED_PHONE,
       STAGING.FN_PHONE_CLEAN(t.INPUT_PHONE) AS ACTUAL_PHONE
FROM VALUES
    ('+64 021 1325689',      '0211325689'),  -- international prefix + extra 0
    ('098373727/0211449638', '098373727'),   -- '/' between two numbers: keep first
    ('06/8710793',           '068710793'),   -- '/' inside one number: keep whole
    ('094807365, extn 5',    '094807365')    -- extension dropped
    AS t(INPUT_PHONE, EXPECTED_PHONE)
WHERE STAGING.FN_PHONE_CLEAN(t.INPUT_PHONE) IS DISTINCT FROM t.EXPECTED_PHONE;

-- -----------------------------------------------------------------------------
-- All tests in one go: one CTE per test (same logic as above), then
-- test_name + failure_count. Every failure_count should be 0.
-- -----------------------------------------------------------------------------
WITH
duplicate_record_key AS (
    SELECT RECORD_KEY
    FROM STAGING.ORGANISATION_STD
    GROUP BY RECORD_KEY
    HAVING COUNT(*) > 1
),
source_row_counts AS (
    SELECT COALESCE(e.SOURCE_SYSTEM, a.SOURCE_SYSTEM) AS SOURCE_SYSTEM
    FROM (SELECT * FROM VALUES ('CHARITIES_REGISTER', 46045), ('COMPANIES_OFFICE', 1664)
              AS v(SOURCE_SYSTEM, EXPECTED_ROWS)) e
    FULL OUTER JOIN (SELECT SOURCE_SYSTEM, COUNT(*) AS ACTUAL_ROWS
                     FROM STAGING.ORGANISATION_STD GROUP BY SOURCE_SYSTEM) a
      ON e.SOURCE_SYSTEM = a.SOURCE_SYSTEM
    WHERE e.EXPECTED_ROWS IS DISTINCT FROM a.ACTUAL_ROWS
),
matchable_without_name AS (
    SELECT RECORD_KEY FROM STAGING.ORGANISATION_STD
    WHERE IS_MATCHABLE AND NAME_CLEAN IS NULL
),
postcode_not_4_digits AS (
    SELECT RECORD_KEY FROM STAGING.ORGANISATION_STD
    WHERE POSTCODE IS NOT NULL AND NOT REGEXP_LIKE(POSTCODE, '^[0-9]{4}$')
),
phone_non_digits AS (
    SELECT RECORD_KEY FROM STAGING.ORGANISATION_STD
    WHERE PHONE_CLEAN IS NOT NULL AND NOT REGEXP_LIKE(PHONE_CLEAN, '^[0-9]+$')
),
nzbn_not_13_digits AS (
    SELECT RECORD_KEY FROM STAGING.ORGANISATION_STD
    WHERE NZBN IS NOT NULL AND NOT REGEXP_LIKE(NZBN, '^[0-9]{13}$')
),
empty_strings_left AS (
    SELECT RECORD_KEY FROM STAGING.ORGANISATION_STD
    WHERE NZBN = '' OR PHONE_CLEAN = '' OR EMAIL_CLEAN = '' OR POSTCODE = ''
),
name_rules AS (
    SELECT t.INPUT_NAME
    FROM VALUES
        ('The Trustees of the Hocken Library Trust', 'HOCKEN LIBRARY TRUST',    'HOCKEN LIBRARY'),
        ('Music Futures Incorporated',               'MUSIC FUTURES INC',       'MUSIC FUTURES'),
        ('Ngāti Awa Farms Limited',                  'NGATI AWA FARMS LTD',     'NGATI AWA FARMS'),
        ('Smith & Sons Company Limited',             'SMITH AND SONS CO LTD',   'SMITH AND SONS CO'),
        ('St. John''s Foundation',                   'ST JOHNS FOUNDATION',     'ST JOHNS FOUNDATION'),
        ('Otago Rugby Society Incorporated',         'OTAGO RUGBY SOCIETY INC', 'OTAGO RUGBY')
        AS t(INPUT_NAME, EXPECTED_CLEAN, EXPECTED_CORE)
    WHERE STAGING.FN_NAME_CLEAN(t.INPUT_NAME) IS DISTINCT FROM t.EXPECTED_CLEAN
       OR STAGING.FN_NAME_CORE(STAGING.FN_NAME_CLEAN(t.INPUT_NAME)) IS DISTINCT FROM t.EXPECTED_CORE
),
phone_rules AS (
    SELECT t.INPUT_PHONE
    FROM VALUES
        ('+64 021 1325689',      '0211325689'),
        ('098373727/0211449638', '098373727'),
        ('06/8710793',           '068710793'),
        ('094807365, extn 5',    '094807365')
        AS t(INPUT_PHONE, EXPECTED_PHONE)
    WHERE STAGING.FN_PHONE_CLEAN(t.INPUT_PHONE) IS DISTINCT FROM t.EXPECTED_PHONE
)
SELECT 'duplicate_record_key'   AS test_name, COUNT(*) AS failure_count FROM duplicate_record_key
UNION ALL SELECT 'source_row_counts',      COUNT(*) FROM source_row_counts
UNION ALL SELECT 'matchable_without_name', COUNT(*) FROM matchable_without_name
UNION ALL SELECT 'postcode_not_4_digits',  COUNT(*) FROM postcode_not_4_digits
UNION ALL SELECT 'phone_non_digits',       COUNT(*) FROM phone_non_digits
UNION ALL SELECT 'nzbn_not_13_digits',     COUNT(*) FROM nzbn_not_13_digits
UNION ALL SELECT 'empty_strings_left',     COUNT(*) FROM empty_strings_left
UNION ALL SELECT 'name_rules',             COUNT(*) FROM name_rules
UNION ALL SELECT 'phone_rules',            COUNT(*) FROM phone_rules;
