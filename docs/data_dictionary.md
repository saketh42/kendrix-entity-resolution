# Data dictionary

Every table, view and helper object built by `sql/01`–`08` and `sql/profiling/`,
grouped by schema. Database `KENDRIX`.

- The database and the four schemas are owned by **Terraform**. `sql/` files only
  create objects inside them.
- `sql/` files run in numeric order; `sql/02`–`08` each append a row to
  `AUDIT.PIPELINE_RUN`. `sql/01` and `sql/profiling/` do not write to it.
- **Contract tables** are created empty by `sql/04` (so column names and types are
  agreed up front) and filled by a later step.
- `TMP_*` tables are `TEMPORARY`: they exist only for the session that ran the file.
- **Rule versions** (written to `AUDIT.PIPELINE_RUN.RULE_VERSION`): `std_v3` (03),
  `block_v1` (04), `feat_v2` (05), `score_v5` (06), `surv_v1` (07).

## RAW - data as received (never edited)

Source columns are all VARCHAR; `_LOADED_AT` is TIMESTAMP_NTZ.

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
| `AUDIT.PIPELINE_RUN` | Table | One row per pipeline step run | `RUN_ID`, `STEP` | Run log: start/end time, rows out, rule version, SUCCESS/FAIL, notes | Created by `sql/01_setup.sql`; steps `02`–`08` append (not `01` or the profiling script) |
| `AUDIT.MATCH_EVIDENCE` | Table (contract) | One row per pair per feature with evidence | `PAIR_ID`, `FEATURE` | Evidence ledger behind every score: both values, similarity, weight, contribution | Created by `sql/04`, filled by `sql/06_matching.sql` |
| `AUDIT.EXCEPTION_QUEUE` | Table (contract) | One row per exception: at most one per pair (from 06), or one per member record of a conflicting master (from 07) | `EXCEPTION_ID`; `PAIR_ID` or `RECORD_KEY` | Items that need a human decision: REVIEW pairs and shared-contact-only near matches (06), and member records of masters where chaining merged two different NZBNs (`CHAIN_NZBN_CONFLICT`, 07) | Created by `sql/04`, filled by `sql/06_matching.sql` and `sql/07_golden_record.sql` |
| `AUDIT.DQ_PROFILE` | Table | One row per data-quality check per profiling run | `RUN_ID`, `SOURCE`, `CHECK_NAME` | Data-quality metrics for RAW (before) and STAGING (after cleaning); feeds `docs/data_quality_report.md` | `sql/profiling/data_quality_profile.sql` |

## Evaluation - sql/08_evaluation.sql

| Object | Type | Grain | Key columns | Purpose | Produced by |
|---|---|---|---|---|---|
| `CURATED.TRUTH_PAIR` | Table | One row per unordered pair of matchable records sharing a valid NZBN held by at most 3 records (1,142) | `LEFT_KEY`, `RIGHT_KEY` (`LEFT_KEY < RIGHT_KEY`) | The answer key, with `PAIR_ID` (NULL if blocking never generated the pair), `IN_CANDIDATES`, `FOUND_WITHOUT_NZBN`, fuzzy score and decision. Rebuilt each run | `sql/08_evaluation.sql` |
| `CURATED.TMP_EVAL_PAIR` | Temporary table | One row per evaluable candidate pair: both sides have an NZBN, not found only by the NZBN block, not an umbrella pair | `PAIR_ID` | Pairs where a fuzzy prediction can be graded right or wrong | `sql/08_evaluation.sql` |
| `AUDIT.EVALUATION_RESULT` | Table | One row per run / metric group / metric | `RUN_ID`, `METRIC_GROUP`, `METRIC` | `METRIC_GROUP`, `METRIC`, `VALUE`, `NOTE` (plus `EVALUATED_AT`, `RULE_VERSION`). Append-only history | `sql/08_evaluation.sql` |
| `CURATED.V_EVAL_EXAMPLES` | View | One row per example: top 10 false positives and top 10 false negatives | `EXAMPLE_TYPE`, `EXAMPLE_RANK` | Names, fuzzy score, decision, top reasons and block types for each example | `sql/08_evaluation.sql` |
