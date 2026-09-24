-- =============================================================================
-- 01_setup.sql
-- Purpose : Create the shared objects every later step relies on: the CSV file
--           format, the internal landing stage and the pipeline run log.
-- Owner   : Data Engineer (Shubham)
-- Inputs  : KENDRIX database and RAW / AUDIT schemas (created by Terraform).
-- Outputs : RAW.FF_CSV         - file format for all source CSVs
--           RAW.LANDING        - internal stage for uploaded source files
--           AUDIT.PIPELINE_RUN - one row per pipeline step run
-- Notes   : Idempotent (IF NOT EXISTS). No database/schema creation here, and
--           no USE WAREHOUSE: the session or CI chooses the warehouse.
-- =============================================================================

USE DATABASE KENDRIX;

-- One file format for every source CSV.
-- FIELD_OPTIONALLY_ENCLOSED_BY is essential: some charities fields contain line
-- breaks inside quotes, and without it one record would split into many rows.
-- EMPTY_FIELD_AS_NULL only affects unquoted empty fields. This source quotes
-- every field, so blanks load as '' and STAGING converts them with
-- NULLIF(TRIM(col), '').
CREATE FILE FORMAT IF NOT EXISTS RAW.FF_CSV
    TYPE = CSV
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    EMPTY_FIELD_AS_NULL = TRUE
    TRIM_SPACE = TRUE
    ENCODING = 'UTF8';

-- Internal stage: the three files from data/clean/ are uploaded here by hand.
CREATE STAGE IF NOT EXISTS RAW.LANDING
    COMMENT = 'Source files uploaded manually via Snowsight';

-- Run log: each SQL step appends one row so runs can be traced and compared.
CREATE TABLE IF NOT EXISTS AUDIT.PIPELINE_RUN (
    RUN_ID        VARCHAR,
    STEP          VARCHAR,
    STARTED_AT    TIMESTAMP_NTZ,
    FINISHED_AT   TIMESTAMP_NTZ,
    ROWS_OUT      NUMBER,
    RULE_VERSION  VARCHAR,
    STATUS        VARCHAR,
    NOTES         VARCHAR
);
