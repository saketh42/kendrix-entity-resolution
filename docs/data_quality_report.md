# Data quality report

**Owner:** Data Analyst (Esha)
**Source of numbers:** `sql/profiling/data_quality_profile.sql` writes to `AUDIT.DQ_PROFILE`.
**RUN_ID used:** see AUDIT.DQ_PROFILE (latest RUN_ID)  **Profiled at:** 24 Sep 2026, 22:48 NZT

Each number comes from the `SOURCE` / `CHECK_NAME` shown next to it in `AUDIT.DQ_PROFILE`.
Abbreviations used in the tables: `RAW.CHR` = `RAW.CHARITIES_ORGANISATIONS`, `RAW.COS` = `RAW.COMPANIES_OFFICE`, `STG` = `STAGING.<SOURCE_SYSTEM>`.

---

## 1. Sources and row counts

| Source | Expected | Actual | Check |
|---|---|---|---|
| Charities Register (RAW) | 46,045 | 46,045 ✅ | `RAW.CHR / row_count` |
| Companies Office (RAW, 2 exports) | 2,000 | 2,000 ✅ | `RAW.COS / row_count` |
| Companies Office (STAGING, after NZBN dedupe) | 1,664 | 1,664 ✅ | `STG.COMPANIES_OFFICE / row_count` |
| Charities Register (STAGING) | 46,045 | 46,045 ✅ | `STG.CHARITIES_REGISTER / row_count` |
| IRD donee list (optional, not profiled) | 39,115 | n/a | none |

## 2. Completeness

% of rows where the field is not blank (blank = `''` after `TRIM`). Check = `pct_nonblank_<FIELD>`.

| Source | Field | % non-blank |
|---|---|---|
| Charities | NAME | 99.99 |
| Charities | CHARITYREGISTRATIONNUMBER | 99.99 |
| Charities | NZBNNUMBER | 64.77 |
| Charities | COMPANIESOFFICENUMBER | 67.54 |
| Charities | EMAILADDRESS1 | 98.63 |
| Charities | TELEPHONE1 | 79.11 |
| Charities | WEBSITEURL | 43.70 |
| Charities | STREETADDRESSLINE1 | 99.47 |
| Charities | STREETADDRESSPOSTCODE | 97.55 |
| Companies Office | BUSINESS_NAME | 96.65 |
| Companies Office | NZBN | 100.00 |
| Companies Office | TRADING_AS | 16.55 |
| Companies Office | PHYSICAL_ADDRESS | 79.05 |

**Key point:** names, emails and street addresses are almost always filled in. NZBN (65%) and website (44%) are the weak fields. About a third of charities have no NZBN, so they cannot be matched by ID, and 21% of Companies Office rows have no address.

## 3. Uniqueness and duplicate signals

| ID | Non-blank | Distinct | Duplicate rows |
|---|---|---|---|
| Charities ORGANISATIONID | 46,045 | 46,045 | 0 |
| Charities CHARITYREGISTRATIONNUMBER | 46,040 | 46,040 | 0 |
| Charities NZBNNUMBER | 29,825 | 28,803 | 1,022 |
| Companies Office NZBN | 2,000 | 1,664 | 336 |

Checks: `<ID>_nonblank`, `<ID>_distinct`, `<ID>_duplicate_rows`. ORGANISATIONID and the registration number are true keys. The 336 Companies Office duplicates are the overlap between the two exports.

| Duplicate signal (charities) | Value | Check |
|---|---|---|
| NZBNs shared by more than one record | 957 | `nzbn_shared_by_multiple_records` |
| Records sharing an exact name (lower bound) | 1,523 | `records_sharing_exact_name` |
| Records with a blank name (privacy-restricted) | 4 | `blank_name_records` |

## 4. Format problems found

| Problem | Records | Check |
|---|---|---|
| Reg number not `CC` + digits | 10 | `reg_no_not_CC_digits` |
| of which group members (`CC11026-1`) | 10 (all of them) | `reg_no_group_member` |
| Phone field holds 2 numbers or an extension (upper bound) | 126 | `phone_multi_number_or_ext` |
| Phone in `+64` / `0064` form | 975 | `phone_intl_nz_prefix` |
| Overseas phone | 85 | `phone_overseas` |
| Street postcode not 4 digits | 1,708 | `street_postcode_not_4_digits` |
| of which 3 digits (lost leading zero) | 1,693 | `street_postcode_3_digits` |
| Postal postcode not 4 digits | 2,038 | `postal_postcode_not_4_digits` |
| Companies Office rows with no Business Name (sole traders) | 67 | `no_business_name` |
| Companies Office rows with no physical address | 419 | `no_physical_address` |

Companies Office entity types (`entity_type=<value>`, raw rows): Incorporated Society 1,177, Sole Trader 295, Partnership 268, Limited Partnership (NZ) 245, Trust 14, Overseas Limited Partnership 1.

**Shared emails** (`shared_email_record_count`, top non-generic addresses; personal addresses masked):

| Email | Records |
|---|---|
| admin@svdp.org.nz | 286 |
| a***@canterbury.ac.nz | 153 |
| n***@stjohn.org.nz | 117 |
| charities@methodist.org.nz | 112 |
| nocharityemail@dia.govt.nz | 94 |
| j***@ngaitahu.iwi.nz | 89 |
| cdafiling@cda.org.nz | 80 |
| noaddress@charities.govt.nz | 73 |
| d***@pbccproperties.com | 43 |
| g***@cdh.org.nz | 40 |

**Placeholder emails:** nocharityemail@dia.govt.nz (94 records) and noaddress@charities.govt.nz (73) are not real emails. They are treated as missing (fix in 03_standardisation, flag PLACEHOLDER_EMAIL) so they cannot create false matches.

## 5. What we did about each problem

| Problem | Decision | Where |
|---|---|---|
| Blanks load as `''`, not NULL | Every source column goes through `NULLIF(TRIM(col), '')`, so blanks never "match" each other | `sql/03`, all columns |
| Privacy-restricted records (no name) | Kept for completeness, `IS_MATCHABLE = FALSE`, flag `RESTRICTED_OR_NO_NAME` | `ORGANISATION_STD.IS_MATCHABLE` |
| Overlapping Companies Office exports | One row per NZBN (first export wins) | `sql/03`, `cos_src` |
| Two numbers or an extension in one phone field | Keep the first number only | `STAGING.FN_PHONE_CLEAN` |
| `+64` / `0064` phones | Converted to local `0...` format | `STAGING.FN_PHONE_CLEAN` |
| Overseas phones | Not compared; flagged `OVERSEAS_PHONE` | `STAGING.FN_PHONE_IS_OVERSEAS` |
| Generic and shared email domains | Not used as match evidence | `IS_GENERIC_EMAIL_DOMAIN` |
| Placeholder emails (nocharityemail@dia.govt.nz 94, noaddress@charities.govt.nz 73) | Treated as missing so they cannot create false matches; flag `PLACEHOLDER_EMAIL` | `sql/03_standardisation.sql` (fixed in std_v2: 169 records, removed 6,922 false candidate pairs (230,880 -> 223,958)) |
| Group-member reg numbers (`CC11026-1`) | Parent number kept separately to link members to their parent | `CHARITY_PARENT_REG_NO` |

Cleaning outcome counts from staging (`dq_flag=<FLAG>`, `not_matchable`):

| Flag | Charities | Companies Office |
|---|---|---|
| MISSING_NZBN | 16,235 | 0 |
| INVALID_PHONE | 245 | n/a |
| ADDRESS_FROM_POSTAL | 129 | n/a |
| OVERSEAS_PHONE | 85 | n/a |
| INVALID_NZBN | 15 | 0 |
| INVALID_POSTCODE | 15 | 0 |
| RESTRICTED_OR_NO_NAME / not_matchable | 4 | 1 |
| NAME_FROM_TRADING_AS | n/a | 52 |

Cross-checks: `OVERSEAS_PHONE` (85) = `phone_overseas` (85). After the 1,693 three-digit postcodes are padded, only 15 street postcodes stay invalid (1,708 − 1,693 = `INVALID_POSTCODE` 15). `MISSING_NZBN` 16,235 = 16,220 blank + 15 invalid.

## 6. Impact on matching

- **Exact ID matches are limited by NZBN coverage:** only 64.77% of charities have an NZBN, so most links must come from names, addresses and contacts.
- **Not matchable:** 5 records (4 charities, plus 1 Companies Office sole trader with no name at all) are excluded from candidate pairs.
- **Emails need care:** 45.77% of charity emails use a generic domain (`pct_generic_email_domain`), and the top shared non-generic email covers 286 records (`shared_email_record_count`). A shared email usually means a shared administrator or accountant, not the same organisation. Placeholder emails must never count as a match.
- **Contact gaps:** the Companies Office has no phone, email or website, so cross-source matches rely on name, address and NZBN only.
- **Duplicates inside the register:** 957 shared NZBNs and 1,523 exact-name records show that within-source matching is also needed.

## 7. Limitations

- Exact-name duplicates are a lower bound: fuzzy matching will find more.
- The phone multi-number count is an upper bound, because `/` is sometimes part of one number (`06/8710793`).
- The Companies Office data is only two search exports (1,664 entities), not the full register.
- The generic email domain list is hand-picked and may miss some shared domains.
- The postal postcode count (2,038) was not split into 3-digit and other values; most are probably lost leading zeros.
- The profile is a snapshot for one `RUN_ID`. Re-run it after any change to RAW or `sql/03`.
