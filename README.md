# Kendrix Entity Resolution

> **[Open Live Dashboard →](https://app.snowflake.com/streamlit/gtwrsqt/fd19514/#/apps/umkziieyqtt3huvkpnon)**


**UoA × dataengine Datathon 2026, Use case 2.** The same New Zealand organisation appears differently across registers. This project builds one trusted master record per organisation in Snowflake. Every match keeps its evidence, and uncertain cases go to a human review queue, so a regulator can see which records belong together and why.

## Results at a glance

| | |
|---|---|
| Source records cleaned | **47,709** (Charities Register 46,045 + Companies Office 1,664) |
| Master organisations | **46,544**, of which 1,132 combine several records and 148 link both sources |
| Candidate pairs compared | 223,361 (blocking avoids ~1.1 billion comparisons) |
| Decisions | AUTO_MATCH 1,187 · REVIEW 11,174 · NO_MATCH 211,000 |
| Auto-merged pairs with conflicting NZBNs | **0**; the rare chains that would join two NZBNs are flagged and queued |
| Fuzzy matching vs NZBN answer key | precision 0.667, recall 0.247; our gates give ~2.5× the precision of the score alone |
| Tests | 51 checks in 6 SQL suites, all 0 failures |

Numbers are from the full run on 25 Sep 2026 (rule versions std_v3, feat_v2, score_v5, surv_v1). Details: [docs/matching_results.md](docs/matching_results.md) and [docs/data_quality_report.md](docs/data_quality_report.md).

## Architecture

```
Source files -> convert_sources.py -> RAW.LANDING stage
  -> RAW (as received) -> STAGING (cleaned) -> CURATED (pairs, features, decisions, masters)
  -> AUDIT (evidence, review queue, run log, data quality, evaluation)
```

- **Snowflake database `KENDRIX`**, with schemas RAW, STAGING, CURATED and AUDIT.
- **Terraform** (run by GitHub Actions) creates the database and schemas. Everything inside them is plain numbered SQL.
- **CI** runs static checks on every pull request.

Diagrams: [docs/architecture.md](docs/architecture.md). Every table and view: [docs/data_dictionary.md](docs/data_dictionary.md).

## How it works

1. **Profile** (`sql/profiling/`): measure data problems before and after cleaning. Examples: placeholder emails, lost postcode zeros, phones with +64, fake NZBNs.
2. **Standardise** (`sql/03`): clean names, addresses, phones, emails and NZBNs with shared UDFs.
3. **Block** (`sql/04`): only compare records that share a postcode plus name start, phone, email, website, name or NZBN. Blocks over 200 records are skipped.
4. **Features** (`sql/05`): name similarity (Jaro-Winkler, forward and reverse), word overlap, contact matches, and how rare each shared value is.
5. **Decide** (`sql/06`): IDs first. The same NZBN with a similar name is a match; different NZBNs are never auto-merged. Otherwise a transparent weighted score plus safety gates decides AUTO_MATCH, REVIEW or NO_MATCH.
6. **Master records** (`sql/07`): cluster the AUTO_MATCH pairs, pick the best value for each field, and keep a link from every master back to its source rows.
7. **Evaluate** (`sql/08`): score the fuzzy matcher against the NZBN answer key, which it never sees.

## How to run

**Prerequisites:**

- Python 3 with `pandas`, `xlrd` and `openpyxl`.
- A Snowflake role with access to database `KENDRIX` (created by Terraform) and any warehouse; we used X-Small.

**Steps:**

1. Put the source exports in `data/raw/`, then run `python scripts/convert_sources.py`. It writes three CSVs to `data/clean/`. Data files are never committed.
2. In Snowsight, run `sql/01_setup.sql`.
3. Upload the three CSVs from `data/clean/` to stage `KENDRIX.RAW.LANDING` (Catalog → RAW → Stages → LANDING → Upload Files).
4. Run the files in order. After each one, run its test file and check that every `failure_count` is 0.

| Step | Pipeline file | Test file |
|---|---|---|
| Load | `sql/02_raw_tables.sql` | built-in row-count check (all PASS) |
| Clean | `sql/03_standardisation.sql` | `tests/sql/test_standardisation.sql` |
| Profile | `sql/profiling/data_quality_profile.sql` | (writes `AUDIT.DQ_PROFILE`) |
| Block | `sql/04_candidates.sql` | `tests/sql/test_candidates.sql` |
| Features | `sql/05_features.sql` | `tests/sql/test_features.sql` |
| Decide | `sql/06_matching.sql` | `tests/sql/test_matching.sql` |
| Masters | `sql/07_golden_record.sql` | `tests/sql/test_golden_record.sql` |
| Evaluate | `sql/08_evaluation.sql` | `tests/sql/test_evaluation.sql` |

Run each file whole, in one worksheet, pasted fresh from the repo: a worksheet keeps its own copy of the code. Snowsight shows only the last result, so every file ends with a summary query.

To run the repository checks locally: `python scripts/ci_checks.py`.

## Auditability: how a regulator uses it

- `CURATED.MASTER_ORGANISATION`: one row per organisation.
- `CURATED.V_ENTITY_LINEAGE`: master → every source record and its original RAW row.
- `AUDIT.MATCH_EVIDENCE`: why each pair was matched or not, one row per piece of evidence.
- `AUDIT.EXCEPTION_QUEUE`: pairs and records that need a human, with a reason:
  - `BORDERLINE_SCORE`
  - `SHARED_CONTACT_ONLY`
  - `ID_CONFLICT_HIGH_NAME`
  - `SHARED_LEGAL_ENTITY`
  - `CHAIN_NZBN_CONFLICT`
- `AUDIT.PIPELINE_RUN`: every run, with its row counts and rule version.

## Limitations

- **Unreachable pairs:** without IDs, 10.7% of true pairs share no block, so fuzzy matching cannot reach them.
- **Noisy answer key:** the NZBN key includes re-registrations, umbrella bodies and a few unrelated organisations sharing one NZBN, so the reported precision and recall are approximate.
- **Large review queue:** there is no review app yet; review happens in Snowsight.
- **Current-state outputs:** re-running 06 or 07 rebuilds the decisions and the queue.
- **Manual upload:** files go to an internal stage (no S3). The SQL and its tests are run manually in Snowsight; CI runs static checks only.
- **Terraform state:** state is not stored remotely, so the next infrastructure change needs a state fix first.
- **IRD donee list:** loaded but not yet matched.
- **Unused scaffolding:** `app/`, `src/`, `infra/` and the dbt workflow are left over from the first plan.

## Roadmap

- Link a Trust and its Limited company as related entities, not as duplicates.
- Former-name lookup.
- Rank the review queue by score, and build a small review app with append-only review history.
- A CI job that runs the SQL and tests in a dev schema.
- Remote Terraform state.
- S3 landing and LINZ address validation.
- Match the IRD donee list.

## Team

| Name | Role | Contribution |
|---|---|---|
| Shubham Gairola | Data Engineer | Source conversion, Snowflake loading, standardisation, blocking, master records and lineage |
| Esha Jain | Data Analyst | Data-quality profiling, match features, matching rules, evaluation, CI checks and documentation |
| Saketh | Data Scientist | Repository setup, Snowflake account, Terraform and GitHub Actions deployment |
| Wennan | Cloud Engineer | Cloud architecture and infrastructure design |
| Saisha | Solution Designer / Project Coordinator | Project plan, coordination, solution design and presentation |

We worked in one branch and one pull request per step, with commits under each person's own git identity.

## Use of AI

Claude and Codex helped draft SQL and documentation under the rules in `CLAUDE.md`. AI never ran SQL or committed code. A team member ran every file in Snowflake, checked the results and tests, and committed it. Several AI suggestions were wrong and were caught by our own tests and data checks; these are the matching v1 to v5 fixes in `sql/06_matching.sql`. A second AI independently audited the repository before submission.
