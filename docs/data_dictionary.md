# Data dictionary

Every table, view and helper object built by `sql/01`–`07` and `sql/profiling/`,
grouped by schema. Database `KENDRIX`.

- The database and the four schemas are owned by **Terraform**. `sql/` files only
  create objects inside them.
- `sql/` files run in numeric order; each one appends a row to `AUDIT.PIPELINE_RUN`.
- **Contract tables** are created empty by `sql/04` (so column names and types are
  agreed up front) and filled by a later step.
- `TMP_*` tables are `TEMPORARY`: they exist only for the session that ran the file.

## RAW - data as received (all columns VARCHAR, never edited)

| Object | Type | Grain | Key columns | Purpose | Produced by |
|---|---|---|---|---|---|
| `RAW.FF_CSV` | File format | - | - | CSV format for all source files (quoted fields may contain line breaks) | `sql/01_setup.sql` |
| `RAW.LANDING` | Internal stage | One file per source | - | Landing area for the files from `data/clean/`, uploaded by hand | `sql/01_setup.sql` |
| `RAW.CHARITIES_ORGANISATIONS` | Table | One row per charity in the Charities Register export (46,045) | `ORGANISATIONID` | The 81 source columns as received, plus `_SOURCE_FILE`, `_LOADED_AT` | `sql/02_raw_tables.sql` |
| `RAW.COMPANIES_OFFICE` | Table | One row per row of the two Companies Office exports (2,000; only 1,664 unique NZBNs because the exports overlap) | `NZBN` + `EXPORT_FILE` | Companies Office search results as received, plus `_SOURCE_FILE`, `_LOADED_AT` | `sql/02_raw_tables.sql` |
| `RAW.IRD_DONEE` | Table | One row per organisation on the IRD donee list (39,115) | `ORGANISATION_NAME` | Optional source: name and ceased date only | `sql/02_raw_tables.sql` |

## STAGING - cleaned and standardised

| Object | Type | Grain | Key columns | Purpose | Produced by |
|---|---|---|---|---|---|
| `STAGING.ORGANISATION_STD` | Table | One row per source record, both sources in one shape (47,709) | `RECORD_KEY` (`CHR:<OrganisationId>` / `COS:<NZBN>`) | Cleaned names, name core, alt names, IDs, address, phone, email, website, status, dates, `IS_MATCHABLE`, `DQ_FLAGS` | `sql/03_standardisation.sql` |
| `STAGING.FN_NAME_CLEAN`, `FN_NAME_CORE`, `FN_PLACE_CLEAN`, `FN_ADDRESS_CLEAN`, `FN_PHONE_IS_OVERSEAS`, `FN_PHONE_CLEAN`, `FN_IS_PLACEHOLDER_EMAIL` | SQL UDFs | One value in, one value out | - | The cleaning rules, written once so every column uses the same logic and they can be unit-tested | `sql/03_standardisation.sql` |

## CURATED - candidate pairs, features, decisions, master, xref

| Object | Type | Grain | Key columns | Purpose | Produced by |
|---|---|---|---|---|---|
| `CURATED.BLOCK_KEY` | Table | One row per matchable record per blocking key | `RECORD_KEY`, `BLOCK_TYPE`, `BLOCK_VALUE` | Every blocking key (postcode + name start, phone, email, website, name, alt name, NZBN), including oversized ones | `sql/04_candidates.sql` |
| `CURATED.BLOCK_SKIPPED` | Table | One row per oversized block (> 200 records) | `BLOCK_TYPE`, `BLOCK_VALUE` | Audit of blocks left out of pairing because they are too generic | `sql/04_candidates.sql` |
| `CURATED.CANDIDATE_PAIR` | Table | One row per pair of records sharing at least one kept block (`LEFT_KEY < RIGHT_KEY`) | `PAIR_ID` (SHA2 of both keys) | Pairs worth comparing, with pair type, block types shared, `ONLY_NZBN_BLOCK` | `sql/04_candidates.sql` |
| `CURATED.MATCH_FEATURE` | Table (contract) | One row per candidate pair | `PAIR_ID` | Field-by-field comparison: name/address similarity, equality flags, word overlap (`NAME_TOKEN_JACCARD`, never NULL), shared-value counts incl. `NZBN_SHARED_COUNT` and `COMPANY_NO_SHARED_COUNT` (how many records carry the shared ID; high = parent/umbrella ID) | Created by `sql/04`, filled by `sql/05_features.sql` |
| `CURATED.MATCH_DECISION` | Table (contract) | One row per candidate pair | `PAIR_ID` | Score and decision (AUTO_MATCH / REVIEW / NO_MATCH), fuzzy-only score/decision, `DECISION_PATH`, top reasons | Created by `sql/04`, filled by `sql/06_matching.sql` |
| `CURATED.TMP_MATCH_EVIDENCE` | Temporary table | One row per pair per feature with evidence | `PAIR_ID`, `FEATURE` | Working copy of the evidence ledger used to compute scores | `sql/06_matching.sql` |
| `CURATED.TMP_PAIR_SCORE` | Temporary table | One row per candidate pair | `PAIR_ID` | Working scores, gates and decisions before they are written to `MATCH_DECISION` | `sql/06_matching.sql` |
| `CURATED.TMP_CLUSTER_EDGE` | Temporary table | One row per AUTO_MATCH pair per direction (2 per pair) | `PAIR_ID`, `FROM_KEY` | Links used for clustering; REVIEW pairs are never included | `sql/07_golden_record.sql` |
| `CURATED.CLUSTER_WORK` | Table | One row per staging record | `RECORD_KEY` | Cluster label per record, worked out by label propagation (`CLUSTER_ID` = smallest `RECORD_KEY` in the cluster) | `sql/07_golden_record.sql` |
| `CURATED.ENTITY_XREF` | Table | One row per staging record | `RECORD_KEY`; `MASTER_ID` | Cross-reference from each source record to its master, with `LINK_TYPE` (SINGLETON / SEED / AUTO_MATCH), `LINK_CONFIDENCE`, `LINK_RULES` | `sql/07_golden_record.sql` |
| `CURATED.MASTER_ORGANISATION` | Table | One row per entity (master) | `MASTER_ID` (`ORG-` + 12 hex chars) | Golden record: surviving name, NZBN, address, contacts, all charity reg. numbers, sources, member count, flags (`NZBN_CONFLICT`, `HAS_OPEN_REVIEW`, `IS_LARGE_CLUSTER`) | `sql/07_golden_record.sql` |
| `CURATED.V_ENTITY_LINEAGE` | View | One row per staging record | `MASTER_ID`, `RECORD_KEY` | Master -> xref -> staging -> RAW row (file, load time), with how and how strongly each record was linked | `sql/07_golden_record.sql` |

## AUDIT - pipeline runs, match evidence, review queue

| Object | Type | Grain | Key columns | Purpose | Produced by |
|---|---|---|---|---|---|
| `AUDIT.PIPELINE_RUN` | Table | One row per pipeline step run | `RUN_ID`, `STEP` | Run log: start/end time, rows out, rule version, SUCCESS/FAIL, notes | Created by `sql/01_setup.sql`; every step `02`–`07` appends |
| `AUDIT.MATCH_EVIDENCE` | Table (contract) | One row per pair per feature with evidence | `PAIR_ID`, `FEATURE` | Evidence ledger behind every score: both values, similarity, weight, contribution | Created by `sql/04`, filled by `sql/06_matching.sql` |
| `AUDIT.EXCEPTION_QUEUE` | Table (contract) | One row per exception: at most one per pair (from 06), or one per member record of a conflicting master (from 07) | `EXCEPTION_ID`; `PAIR_ID` or `RECORD_KEY` | Items that need a human decision: REVIEW pairs and shared-contact-only near matches (06), and member records of masters where chaining merged two different NZBNs (`CHAIN_NZBN_CONFLICT`, 07) | Created by `sql/04`, filled by `sql/06_matching.sql` and `sql/07_golden_record.sql` |
| `AUDIT.DQ_PROFILE` | Table | One row per data-quality check per profiling run | `RUN_ID`, `SOURCE`, `CHECK_NAME` | Data-quality metrics for RAW (before) and STAGING (after cleaning); feeds `docs/data_quality_report.md` | `sql/profiling/data_quality_profile.sql` |
