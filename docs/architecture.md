# Architecture

Everything runs in one Snowflake database, `KENDRIX`, as plain numbered SQL files. Each step has a test suite. GitHub holds the code, and GitHub Actions runs Terraform (infrastructure) and static CI checks.

## End-to-end flow

```mermaid
flowchart LR
    subgraph SRC["Source files"]
        CH["Charities Register CSV<br/>46,045 rows"]
        CO["Companies Office XLS<br/>2,000 rows"]
        IRD["IRD donee XLSX<br/>39,115 rows"]
    end

    CH --> PY["scripts/convert_sources.py"]
    CO --> PY
    IRD --> PY
    PY --> UP["Manual upload in Snowsight"]
    UP --> STG[("RAW.LANDING<br/>internal stage")]

    subgraph SF["Snowflake database KENDRIX"]
        STG --> RAW["RAW<br/>02: source tables, all text"]
        RAW --> STD["STAGING<br/>03: ORGANISATION_STD<br/>47,709 cleaned records"]
        STD --> BLK["CURATED<br/>04: blocking -> CANDIDATE_PAIR<br/>223,361 pairs"]
        BLK --> FEAT["CURATED<br/>05: MATCH_FEATURE"]
        FEAT --> DEC["CURATED<br/>06: MATCH_DECISION<br/>AUTO / REVIEW / NO_MATCH"]
        DEC --> GR["CURATED<br/>07: MASTER_ORGANISATION<br/>ENTITY_XREF, V_ENTITY_LINEAGE<br/>46,544 masters"]
        DEC --> EVD[("AUDIT.MATCH_EVIDENCE")]
        DEC --> Q[("AUDIT.EXCEPTION_QUEUE")]
        GR --> Q
        STD --> DQ[("AUDIT.DQ_PROFILE")]
        DEC --> EV[("AUDIT.EVALUATION_RESULT<br/>08")]
    end

    subgraph GH["GitHub"]
        PR["Pull request per step"] --> TF["Actions: Terraform<br/>plan on PR, apply on main"]
        PR --> CI["Actions: CI static checks"]
    end
    TF --> DB["Creates KENDRIX +<br/>RAW, STAGING, CURATED, AUDIT"]
```

## Layers

| Schema | Holds | Created by |
|---|---|---|
| RAW | Source rows as received (all text), plus file name and load time | `sql/02_raw_tables.sql` |
| STAGING | One cleaned row per organisation record, plus the cleaning UDFs | `sql/03_standardisation.sql` |
| CURATED | Blocking keys, candidate pairs, features, decisions, master records, lineage view | `sql/04` to `sql/08` |
| AUDIT | Run log, evidence per decision, human review queue, data-quality profile, evaluation metrics | `sql/01`, `06`, `07`, `08`, `sql/profiling/` |

Terraform creates only the database and the four schemas. Everything inside them comes from the SQL files, so the SQL can be re-run on its own.

## How one pair is decided (sql/06)

```mermaid
flowchart TD
    P["Candidate pair"] --> ID{"Both records have<br/>an NZBN / company no.?"}
    ID -- "same ID, similar name" --> A1["AUTO_MATCH<br/>(ID_MATCH)"]
    ID -- "same ID, different name" --> R1["REVIEW<br/>(SHARED_LEGAL_ENTITY)"]
    ID -- "different IDs" --> C{"Name similarity >= 95?"}
    C -- yes --> R2["REVIEW<br/>(ID_CONFLICT_HIGH_NAME)"]
    C -- no --> N1["NO_MATCH<br/>(ID_CONFLICT)"]
    ID -- "no usable ID" --> S["Weighted score:<br/>name 40, address 15, postcode 10,<br/>city 5, phone 15, email 15, website 10<br/>(rare values count more)"]
    S --> G{"Score >= 85, name >= 85,<br/>word overlap >= 0.75,<br/>second piece of evidence?"}
    G -- yes --> A2["AUTO_MATCH (FUZZY)"]
    G -- "no, score >= 75" --> R3["REVIEW<br/>(BORDERLINE_SCORE or<br/>SHARED_CONTACT_ONLY)"]
    G -- "no, score < 75" --> N2["NO_MATCH"]
```

Every decision writes its reasons to `AUDIT.MATCH_EVIDENCE`, and every REVIEW goes to `AUDIT.EXCEPTION_QUEUE`. An ID shared by more than 3 records is treated as a parent or umbrella ID, not an identity.

## From pairs to master records (sql/07)

1. Only AUTO_MATCH pairs link records. Linked records form a cluster (label propagation).
2. Each cluster becomes one row in `MASTER_ORGANISATION`, and the best value for each field is chosen by fixed rules.
3. `ENTITY_XREF` maps every source record to its master. `V_ENTITY_LINEAGE` shows the original RAW row behind each one.
4. If a chain of matches joins records with different NZBNs, the cluster is flagged and every member goes to the queue as `CHAIN_NZBN_CONFLICT`.

## Design choices

- **Plain SQL in Snowflake, not dbt or Python.** Simple to review, run and explain; every rule is visible.
- **Internal stage, not S3.** No cloud storage integration was needed for a prototype. S3 is on the roadmap.
- **Transparent weighted score, not ML.** Weights and thresholds are variables at the top of `sql/06_matching.sql`, so a regulator can see why each pair matched.
- **Human in the loop.** Uncertain pairs are queued with a reason code, not guessed.
