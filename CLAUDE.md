# CLAUDE.md — rules for AI assistants

## Project
- Kendrix entity resolution (datathon use case 2).
- Platform: Snowflake only, plus GitHub Actions and Terraform. Nothing outside AWS/Snowflake.

## Snowflake layout
- Database `KENDRIX`, warehouse `TEAM_WH` (XSMALL).
- Schemas:
  - `RAW`: data as received, all columns VARCHAR, never edited.
  - `STAGING`: cleaned and standardised.
  - `CURATED`: candidate pairs, features, decisions, master, xref.
  - `AUDIT`: pipeline runs, match evidence, exception/review queue.

## Terraform vs sql/
- Terraform owns the database and schemas ONLY.
- `sql/` files own tables, views and logic. Never create databases or schemas in `sql/`.

## SQL conventions
- `sql/` files run in numeric order. They must be idempotent (`CREATE OR REPLACE` / `IF NOT EXISTS`) and runnable top to bottom in Snowsight.
- Every file starts with a header comment covering purpose, owner, inputs and outputs.
- Uppercase keywords, one CTE per logical step, and a comment explaining WHY for every non-obvious rule.
- Prefer simple, explainable rules over clever code.

## File ownership
- Data Engineer (Shubham): `sql/01`, `02`, `03`, `04`, `07`, `scripts/`, `docs/data_dictionary.md`.
- Data Analyst (Esha): `sql/05`, `06`, `08`, `sql/profiling/`, `docs/data_quality_report.md`, `docs/matching_results.md`.
- Do not edit the other person's files unless asked.

## Data and secrets
- Never commit `data/` (except small `data/sample/*.csv` fixtures), credentials, private keys or tfstate changes.
- Never put credentials in code.

## AI assistant rules
- Do not run `git commit` / `git push` and do not connect to Snowflake. Humans run SQL and commit.
- Explain every AI-written block to the human before it is committed.

## Source facts
- `charities_organisations.csv`: 46,045 rows, 81 columns, UTF-8, CRLF. Some quoted fields contain line breaks.
  - Primary key `OrganisationId` (`CharityRegistrationNumber` has 5 nulls).
- Companies Office exports: 2 `.xls` files, 1,000 rows each.
  - 5 junk rows sit above the header row, which starts "Business Name".
  - The last two columns are unlabelled (= `STATUS`, `STATUS_DATE`).
  - Only 1,664 unique NZBNs across 2,000 rows, because the two searches overlap.
  - 67 rows with no Business Name (sole traders, only Trading As).
- IRD donee list: 39,115 rows, name and ceased date only (optional source).
- `scripts/convert_sources.py` converts `data/raw/` into `data/clean/*.csv` for loading into RAW.
