-- =============================================================================
-- 06_matching.sql
-- Purpose : Scoring and decisions. Turns the pair features from step 05 into a
--           transparent weighted score (0-100) and a decision per candidate
--           pair (AUTO_MATCH / REVIEW / NO_MATCH), writes the per-feature
--           evidence behind every score, and queues pairs that need a human.
-- Owner   : Data Analyst (Esha)
-- Inputs  : CURATED.MATCH_FEATURE    (223,958 rows, built by sql/05)
--           CURATED.CANDIDATE_PAIR   (built by sql/04)
--           STAGING.ORGANISATION_STD (built by sql/03) - values for the evidence
-- Outputs : CURATED.MATCH_DECISION   - one row per candidate pair
--           AUDIT.MATCH_EVIDENCE     - one row per pair per feature with evidence
--           AUDIT.EXCEPTION_QUEUE    - pairs that need a human decision
--           one row in AUDIT.PIPELINE_RUN (step '06_matching')
-- Notes   : Idempotent: new columns use ADD COLUMN IF NOT EXISTS, output tables
--           are truncated and fully rebuilt on every run. Rule version 'score_v5'.
--           v5 (after golden-record review of v4: different St John area
--           committees with no NZBN auto-merged through a shared COMPANY_NO,
--           which is the parent entity's number): every word-overlap gate
--           treats a missing NAME_TOKEN_JACCARD as 0 (fail, not skip), and an
--           ID match only auto-merges if that ID is on at most ID_SHARED_MAX
--           records; a more widely shared ID goes to REVIEW.
--           v4 (after results review of v3: ID_MATCH merged branches of one
--           legal entity, e.g. 'St John Kawhia Area Committee' <-> 'St John
--           Murupara Area Committee', same NZBN): an ID match whose names share
--           less than AUTO_JACCARD (75%) of their words goes to REVIEW, not
--           AUTO_MATCH. One word-overlap threshold for every auto-merge.
--           v3 (after results review of v2: 2,502 AUTO / 19,263 REVIEW, with
--           false matches that share start AND end but differ in the key word,
--           e.g. 'Ngati Tu Hapu Charitable Trust' <-> 'Ngati Haua Hapu
--           Charitable Trust'): word-overlap (Jaccard) gate on AUTO_MATCH and
--           a name cap when fewer than half the words are shared.
--           v2 (after results review of v1: 13,208 AUTO / 66,289 REVIEW, with
--           false matches like 'Estate of Andrew Black' <-> 'Estate of Kenneth
--           Arnold North'): reversed-name check against the Jaro-Winkler prefix
--           bonus, rarity on address/postcode/city, REVIEW threshold 65 -> 75.
--           Two decisions per pair:
--             FUZZY_SCORE / FUZZY_DECISION - names, address and contacts only,
--               NO identifiers, so the evaluation measures fuzzy matching honestly.
--             SCORE / DECISION / DECISION_PATH - production: identifier rules
--               first (NZBN, company number, charity group), then the fuzzy result.
--           Working data lives in two TEMPORARY tables (gone when the session
--           ends), so the scoring logic is written once and reused.
--           Tests: tests/sql/test_matching.sql.
-- =============================================================================

USE DATABASE KENDRIX;

-- One RUN_ID for this run, shared by every row and the audit log entry.
-- SET only accepts constants or subqueries, so function calls are wrapped in (SELECT ...).
SET RUN_ID = (SELECT UUID_STRING());
SET STARTED_AT = (SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
SET RULE_VERSION = 'score_v5';

-- -----------------------------------------------------------------------------
-- 0) ALL weights and thresholds, in one place. Change them here only.
--
--    FUZZY_SCORE = SUM(weight * similarity) / SUM(weight), over the features
--    that HAVE evidence for this pair. A NULL feature (one side missing the
--    value) is left out and its weight leaves the denominator: missing is not
--    the same as different. A FALSE / low feature keeps its weight and adds 0.
-- -----------------------------------------------------------------------------

-- Weights (they add up to 110; only the ratio between them matters, because
-- the score is divided by the sum of the weights actually used).
-- Name is the main signal: every record has one and the whole task is "same
-- organisation, written differently".
SET W_NAME     = 40;
-- Street address: strong when present, but formats vary (PO boxes, levels).
SET W_ADDRESS  = 15;
-- Postcode: confirms the same area; many organisations share one, so it is
-- worth less than a full address.
SET W_POSTCODE = 10;
-- City: very coarse (thousands of charities in Auckland), a small nudge only.
SET W_CITY     = 5;
-- Direct contacts: a phone or email used by only these two records is close
-- to identity evidence.
SET W_PHONE    = 15;
SET W_EMAIL    = 15;
-- Website: good evidence, but some organisations share an umbrella site.
SET W_WEBSITE  = 10;

-- Name (v2): the name similarity is the LOWER of forward and reversed
-- Jaro-Winkler on NAME_CORE. Forward JW rewards a shared start, so every
-- 'ESTATE OF ...' pair looked similar; reversed JW compares the endings, where
-- 'BLACK' vs 'NORTH' clearly differ. Alt names can still carry a
-- former/trading-name match, but on their own are capped at ALT_NAME_CAP.
-- (v3: the v2 alt-name score was forward-only and let the prefix bias back
-- in; sql/05 now applies the same forward/reversed LEAST to alt names.)
SET ALT_NAME_CAP   = 90;
-- Name (v3): Jaro-Winkler compares letters, so 'GISBORNE CITY SAFE' and
-- 'GISBORNE PRESBYTERIAN PARISH' can still look close. NAME_TOKEN_JACCARD
-- (sql/05) is the share of distinct words both names have. Below
-- LOW_JACCARD they share fewer than half their words, so they are not the
-- same name: the name similarity is capped at LOW_JACCARD_NAME_CAP.
SET LOW_JACCARD          = 0.5;
SET LOW_JACCARD_NAME_CAP = 70;

-- Rarity of a shared contact (how many records in the register carry it).
-- E2 found 41,579 of 48,011 email-sharing pairs use an email on more than 10
-- records: accountant/admin addresses that say nothing about identity.
-- v2: the same factor now applies to address, postcode and city, using
-- ADDRESS_SHARED_COUNT (address + postcode): the v1 estate false matches all
-- sat at one trustee company's address, which is not identity evidence.
-- <= RARE_MAX records   -> full weight (a small family of records).
-- <= SHARED_MAX records -> half weight (maybe a small group, maybe an agent).
-- >  SHARED_MAX records -> weight 0: treated as no evidence at all.
SET RARE_MAX       = 3;
SET SHARED_MAX     = 10;
SET RARITY_SHARED  = 0.5;

-- v5: an identifier (NZBN / company number) shared by more records than this
-- is a parent or umbrella body's ID, not an identity: every St John area
-- committee carries the parent's company number. An ID shared by many records
-- is not an identity, the same rule we apply to emails and addresses above,
-- so such a pair goes to REVIEW instead of ID_MATCH. Same limit as RARE_MAX.
SET ID_SHARED_MAX  = 3;

-- Decision thresholds.
-- AUTO_MATCH needs a high overall score AND a high name AND one agreeing
-- non-name feature, so a name alone (two different 'Lions Club' branches)
-- can never auto-merge.
SET AUTO_SCORE     = 85;
SET AUTO_NAME      = 85;
-- v3: AUTO_MATCH also needs at least 3 of every 4 distinct words shared.
-- 'MERCURY BAY SKATE PARK' vs 'MERCURY BAY RSA POPPY' shares 2 of 6 words
-- and no longer auto-merges. A pair that fails only this gate goes to REVIEW.
-- v4: the SAME threshold also gates ID matches (same NZBN / company number):
-- one legal entity can hold several differently named registered charities
-- (St John area committees), likely branches, so a human decides whether to
-- merge them. One word-overlap threshold for every auto-merge.
SET AUTO_JACCARD   = 0.75;
-- An address this similar counts as the second, non-name piece of evidence.
SET SECOND_ADDRESS = 85;
-- Between REVIEW_SCORE and AUTO: plausible, needs a human.
-- v2: raised from 65 to 75. At 65, v1 queued 66,289 pairs, far more than a
-- team can review. AUTO_MATCH stays at 85.
SET REVIEW_SCORE   = 75;
-- Score cap for NO_MATCH on the ID/group rules, so a NO_MATCH never shows a
-- score that looks like a match (kept below REVIEW_SCORE).
SET ID_CONFLICT_CAP = 40;
-- Different NZBNs but a near-identical name: possibly a typo in an NZBN, so
-- a human looks at it instead of an automatic NO_MATCH.
SET ID_CONFLICT_REVIEW_NAME = 95;
-- Very similar name whose only other agreement is a heavily shared contact:
-- not enough to match, too suspicious to drop silently.
SET SHARED_CONTACT_NAME = 90;

-- -----------------------------------------------------------------------------
-- 1) New columns on the contract table from sql/04.
--    FUZZY_* ignores NZBN / company number so the evaluation can measure fuzzy
--    matching honestly (a shared NZBN is close to the answer itself).
--    DECISION / SCORE is the production decision.
--    One ALTER per column: IF NOT EXISTS then applies to each column separately.
-- -----------------------------------------------------------------------------
ALTER TABLE CURATED.MATCH_DECISION ADD COLUMN IF NOT EXISTS FUZZY_SCORE NUMBER(5,2)
    COMMENT 'Weighted score from names/address/contacts only (no NZBN/company no.), 0-100; used by the evaluation';
ALTER TABLE CURATED.MATCH_DECISION ADD COLUMN IF NOT EXISTS FUZZY_DECISION VARCHAR
    COMMENT 'AUTO_MATCH / REVIEW / NO_MATCH from FUZZY_SCORE and its gates only';
ALTER TABLE CURATED.MATCH_DECISION ADD COLUMN IF NOT EXISTS DECISION_PATH VARCHAR
    COMMENT 'Rule that set DECISION: ID_MATCH / ID_MATCH_NAME_DIFFERS / ID_CONFLICT / ID_CONFLICT_REVIEW / RELATED_GROUP_MEMBER / FUZZY';

-- -----------------------------------------------------------------------------
-- 2) Evidence, long format: one row per pair per feature that has evidence.
--    This is the single place where similarity and effective weight are set;
--    the score, the decisions and AUDIT.MATCH_EVIDENCE all read from it.
--    IN_SCORE = FALSE marks the identifier rows (NZBN, company no., parent
--    charity): kept so the ledger explains ID decisions, but not in the sum.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE CURATED.TMP_MATCH_EVIDENCE AS
WITH
-- Features plus both records' actual values (L_ = left, R_ = right).
pairs AS (
    SELECT
        f.PAIR_ID,
        f.NAME_JW, f.NAME_CORE_JW, f.NAME_CORE_JW_REV, f.ALT_NAME_JW, f.ADDRESS_JW,
        f.ADDRESS_SHARED_COUNT, f.NAME_TOKEN_JACCARD,
        f.POSTCODE_EQ, f.CITY_EQ, f.PHONE_EQ, f.EMAIL_EQ, f.WEBSITE_EQ,
        f.NZBN_EQ, f.COMPANY_NO_EQ, f.SAME_PARENT_CHARITY,
        f.PHONE_SHARED_COUNT, f.EMAIL_SHARED_COUNT, f.WEBSITE_SHARED_COUNT,
        COALESCE(l.NAME_CORE, l.NAME_CLEAN) AS L_NAME, COALESCE(r.NAME_CORE, r.NAME_CLEAN) AS R_NAME,
        l.ADDRESS_LINE_CLEAN    AS L_ADDR,   r.ADDRESS_LINE_CLEAN    AS R_ADDR,
        l.POSTCODE              AS L_PC,     r.POSTCODE              AS R_PC,
        l.CITY                  AS L_CITY,   r.CITY                  AS R_CITY,
        l.PHONE_CLEAN           AS L_PHONE,  r.PHONE_CLEAN           AS R_PHONE,
        l.EMAIL_CLEAN           AS L_EMAIL,  r.EMAIL_CLEAN           AS R_EMAIL,
        l.WEBSITE_DOMAIN        AS L_WEB,    r.WEBSITE_DOMAIN        AS R_WEB,
        l.NZBN                  AS L_NZBN,   r.NZBN                  AS R_NZBN,
        l.COMPANY_NO            AS L_CO,     r.COMPANY_NO            AS R_CO,
        l.CHARITY_PARENT_REG_NO AS L_PARENT, r.CHARITY_PARENT_REG_NO AS R_PARENT
    FROM CURATED.MATCH_FEATURE f
    JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = f.PAIR_ID
    JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
    JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
),

-- Rarity factor per contact. Only applied when the pair is EQUAL on the value
-- (the shared count describes the shared value); a FALSE keeps full weight,
-- because two different contacts are real evidence of difference.
rarity AS (
    SELECT
        p.*,
        CASE
            WHEN NOT COALESCE(p.PHONE_EQ, FALSE)    THEN 1.0
            WHEN p.PHONE_SHARED_COUNT <= $RARE_MAX   THEN 1.0
            WHEN p.PHONE_SHARED_COUNT <= $SHARED_MAX THEN $RARITY_SHARED
            ELSE 0
        END AS PHONE_RARITY,
        CASE
            WHEN NOT COALESCE(p.EMAIL_EQ, FALSE)    THEN 1.0
            WHEN p.EMAIL_SHARED_COUNT <= $RARE_MAX   THEN 1.0
            WHEN p.EMAIL_SHARED_COUNT <= $SHARED_MAX THEN $RARITY_SHARED
            ELSE 0
        END AS EMAIL_RARITY,
        CASE
            WHEN NOT COALESCE(p.WEBSITE_EQ, FALSE) THEN 1.0
            -- Generic hosting/social hosts (same list as blk_website in sql/04):
            -- facebook.com/x and facebook.com/y are different organisations,
            -- so sharing the host is no evidence however rare it looks.
            WHEN p.L_WEB IN ('facebook.com', 'google.com', 'sites.google.com',
                             'wixsite.com', 'wordpress.com', 'blogspot.com', 'weebly.com')
              OR REGEXP_LIKE(p.L_WEB, '.*[.](facebook|google)[.]com') THEN 0
            WHEN p.WEBSITE_SHARED_COUNT <= $RARE_MAX   THEN 1.0
            WHEN p.WEBSITE_SHARED_COUNT <= $SHARED_MAX THEN $RARITY_SHARED
            ELSE 0
        END AS WEBSITE_RARITY,
        -- v2: address/postcode/city. Applied whether or not they agree: if
        -- either record sits at a busy trustee/accountant address, comparing
        -- locations says little either way. No count (a side lacks address or
        -- postcode) = no information about sharing, so full weight.
        CASE
            WHEN p.ADDRESS_SHARED_COUNT IS NULL         THEN 1.0
            WHEN p.ADDRESS_SHARED_COUNT <= $RARE_MAX     THEN 1.0
            WHEN p.ADDRESS_SHARED_COUNT <= $SHARED_MAX   THEN $RARITY_SHARED
            ELSE 0
        END AS ADDRESS_RARITY
    FROM pairs p
),

-- Name (v2): core name = LEAST(forward, reversed) JW, so both the start AND the
-- end of the names must agree. Alt names can still win, capped at ALT_NAME_CAP
-- (since v3, sql/05 also takes forward/reversed LEAST for each alt-name
-- combination). LEAST/GREATEST return NULL if any argument is NULL, hence the
-- COALESCEs: NAME_JW covers a missing NAME_CORE, and a missing reversed score
-- falls back to the forward one.
-- v3: if the names share fewer than LOW_JACCARD of their words, the result is
-- capped at LOW_JACCARD_NAME_CAP.
-- v5: a NULL Jaccard counts as 0 (so the cap applies): a missing value must
-- fail a gate, never skip it.
name_sim AS (
    SELECT r.*,
           GREATEST(
               LEAST(COALESCE(NAME_CORE_JW, NAME_JW, 0),
                     COALESCE(NAME_CORE_JW_REV, NAME_CORE_JW, NAME_JW, 0)),
               LEAST(COALESCE(ALT_NAME_JW, 0), $ALT_NAME_CAP)
           ) AS NAME_SIM_UNCAPPED
    FROM rarity r
),
ev_name AS (
    SELECT PAIR_ID, 'NAME_BEST_JW' AS FEATURE, L_NAME AS LEFT_VALUE, R_NAME AS RIGHT_VALUE,
           IFF(COALESCE(NAME_TOKEN_JACCARD, 0) < $LOW_JACCARD,
               LEAST(NAME_SIM_UNCAPPED, $LOW_JACCARD_NAME_CAP),
               NAME_SIM_UNCAPPED) AS SIMILARITY,
           $W_NAME AS EFF_WEIGHT, TRUE AS IN_SCORE
    FROM name_sim
),
ev_address AS (
    SELECT PAIR_ID, 'ADDRESS_JW', L_ADDR, R_ADDR, ADDRESS_JW, $W_ADDRESS * ADDRESS_RARITY, TRUE
    FROM rarity
    WHERE ADDRESS_JW IS NOT NULL
),
ev_postcode AS (
    SELECT PAIR_ID, 'POSTCODE_EQ', L_PC, R_PC, IFF(POSTCODE_EQ, 100, 0), $W_POSTCODE * ADDRESS_RARITY, TRUE
    FROM rarity
    WHERE POSTCODE_EQ IS NOT NULL
),
ev_city AS (
    SELECT PAIR_ID, 'CITY_EQ', L_CITY, R_CITY, IFF(CITY_EQ, 100, 0), $W_CITY * ADDRESS_RARITY, TRUE
    FROM rarity
    WHERE CITY_EQ IS NOT NULL
),
ev_phone AS (
    SELECT PAIR_ID, 'PHONE_EQ', L_PHONE, R_PHONE, IFF(PHONE_EQ, 100, 0), $W_PHONE * PHONE_RARITY, TRUE
    FROM rarity
    WHERE PHONE_EQ IS NOT NULL
),
-- EMAIL_EQ is already NULL for generic (free-mail/trustee) domains, see sql/05.
ev_email AS (
    SELECT PAIR_ID, 'EMAIL_EQ', L_EMAIL, R_EMAIL, IFF(EMAIL_EQ, 100, 0), $W_EMAIL * EMAIL_RARITY, TRUE
    FROM rarity
    WHERE EMAIL_EQ IS NOT NULL
),
ev_website AS (
    SELECT PAIR_ID, 'WEBSITE_EQ', L_WEB, R_WEB, IFF(WEBSITE_EQ, 100, 0), $W_WEBSITE * WEBSITE_RARITY, TRUE
    FROM rarity
    WHERE WEBSITE_EQ IS NOT NULL
),
-- Identifier rows: rule evidence only (WEIGHT NULL), never in the fuzzy sum.
ev_nzbn AS (
    SELECT PAIR_ID, 'NZBN_EQ', L_NZBN, R_NZBN, IFF(NZBN_EQ, 100, 0), NULL, FALSE
    FROM rarity
    WHERE NZBN_EQ IS NOT NULL
),
ev_company_no AS (
    SELECT PAIR_ID, 'COMPANY_NO_EQ', L_CO, R_CO, IFF(COMPANY_NO_EQ, 100, 0), NULL, FALSE
    FROM rarity
    WHERE COMPANY_NO_EQ IS NOT NULL
),
ev_same_parent AS (
    SELECT PAIR_ID, 'SAME_PARENT_CHARITY', L_PARENT, R_PARENT, IFF(SAME_PARENT_CHARITY, 100, 0), NULL, FALSE
    FROM rarity
    WHERE SAME_PARENT_CHARITY IS NOT NULL
),

all_ev AS (
    SELECT * FROM ev_name
    UNION ALL SELECT * FROM ev_address
    UNION ALL SELECT * FROM ev_postcode
    UNION ALL SELECT * FROM ev_city
    UNION ALL SELECT * FROM ev_phone
    UNION ALL SELECT * FROM ev_email
    UNION ALL SELECT * FROM ev_website
    UNION ALL SELECT * FROM ev_nzbn
    UNION ALL SELECT * FROM ev_company_no
    UNION ALL SELECT * FROM ev_same_parent
)

-- CONTRIBUTION = this feature's share of the final fuzzy score, so a pair's
-- contributions add up to its FUZZY_SCORE (up to rounding). Denominator = the
-- pair's total effective weight of scoring features (>= W_NAME, never 0).
SELECT
    PAIR_ID::VARCHAR                                AS PAIR_ID,
    FEATURE::VARCHAR                                AS FEATURE,
    LEFT_VALUE::VARCHAR                             AS LEFT_VALUE,
    RIGHT_VALUE::VARCHAR                            AS RIGHT_VALUE,
    SIMILARITY::NUMBER(5,2)                         AS SIMILARITY,
    EFF_WEIGHT::NUMBER(5,2)                         AS EFF_WEIGHT,
    IN_SCORE::BOOLEAN                               AS IN_SCORE,
    IFF(IN_SCORE,
        ROUND(EFF_WEIGHT * SIMILARITY
              / NULLIF(SUM(IFF(IN_SCORE, EFF_WEIGHT, 0)) OVER (PARTITION BY PAIR_ID), 0), 2),
        NULL)::NUMBER(6,2)                          AS CONTRIBUTION
FROM all_ev;

-- -----------------------------------------------------------------------------
-- 3) One row per pair: fuzzy score, gates, fuzzy decision, production decision.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE CURATED.TMP_PAIR_SCORE AS
WITH
fuzzy AS (
    SELECT
        PAIR_ID,
        ROUND(SUM(IFF(IN_SCORE, EFF_WEIGHT * SIMILARITY, 0))
              / NULLIF(SUM(IFF(IN_SCORE, EFF_WEIGHT, 0)), 0), 2)       AS FUZZY_SCORE,
        MAX(IFF(FEATURE = 'NAME_BEST_JW', SIMILARITY, NULL))          AS NAME_SCORE,
        -- A second, non-name agreement. City is left out on purpose: too
        -- coarse to confirm identity. Anything with weight 0 (a heavily
        -- shared contact or, since v2, a busy trustee address) does not count.
        BOOLOR_AGG(
               (FEATURE = 'ADDRESS_JW'  AND SIMILARITY >= $SECOND_ADDRESS AND EFF_WEIGHT > 0)
            OR (FEATURE = 'POSTCODE_EQ' AND SIMILARITY = 100 AND EFF_WEIGHT > 0)
            OR (FEATURE IN ('PHONE_EQ', 'EMAIL_EQ', 'WEBSITE_EQ') AND SIMILARITY = 100 AND EFF_WEIGHT > 0)
        )                                                             AS HAS_SECOND_EVIDENCE,
        -- The pair agrees on a contact that is so widely shared it got weight 0.
        BOOLOR_AGG(FEATURE IN ('PHONE_EQ', 'EMAIL_EQ', 'WEBSITE_EQ') AND SIMILARITY = 100 AND EFF_WEIGHT = 0)
                                                                      AS HAS_SHARED_CONTACT
    FROM CURATED.TMP_MATCH_EVIDENCE
    GROUP BY PAIR_ID
),

-- The 3 features that added the most points, most important first. Features
-- adding 0 are not reasons. FEATURE breaks ties so the order is repeatable.
top_reasons AS (
    SELECT PAIR_ID,
           ARRAY_AGG(FEATURE) WITHIN GROUP (ORDER BY CONTRIBUTION DESC, FEATURE) AS REASONS
    FROM (
        SELECT PAIR_ID, FEATURE, CONTRIBUTION,
               ROW_NUMBER() OVER (PARTITION BY PAIR_ID ORDER BY CONTRIBUTION DESC, FEATURE) AS RN
        FROM CURATED.TMP_MATCH_EVIDENCE
        WHERE CONTRIBUTION > 0
    )
    WHERE RN <= 3
    GROUP BY PAIR_ID
),

fuzzy_decided AS (
    SELECT
        fz.PAIR_ID, fz.FUZZY_SCORE, fz.NAME_SCORE, fz.HAS_SECOND_EVIDENCE,
        (fz.HAS_SHARED_CONTACT AND NOT fz.HAS_SECOND_EVIDENCE)      AS HAS_SHARED_CONTACT_ONLY,
        mf.NZBN_EQ, mf.COMPANY_NO_EQ, mf.SAME_PARENT_CHARITY, mf.NAME_TOKEN_JACCARD,
        -- v5: how many records carry the identifier that would drive an ID
        -- match: the NZBN when it matches, otherwise the company number (only
        -- used when there is no NZBN evidence, same as rule a below).
        CASE
            WHEN mf.NZBN_EQ                                  THEN mf.NZBN_SHARED_COUNT
            WHEN mf.COMPANY_NO_EQ AND mf.NZBN_EQ IS NULL     THEN mf.COMPANY_NO_SHARED_COUNT
        END                                                         AS ID_SHARED_COUNT,
        COALESCE(tr.REASONS, ARRAY_CONSTRUCT())                     AS REASONS,
        -- Gates on top of the score: a high score from the name alone must
        -- not auto-merge; it falls through to REVIEW instead (a score >=
        -- AUTO_SCORE is always >= REVIEW_SCORE). v3 adds the word-overlap
        -- gate; a NULL Jaccard (no words to compare) fails it.
        CASE
            WHEN fz.FUZZY_SCORE >= $AUTO_SCORE
             AND fz.NAME_SCORE  >= $AUTO_NAME
             AND fz.HAS_SECOND_EVIDENCE
             AND COALESCE(mf.NAME_TOKEN_JACCARD, 0) >= $AUTO_JACCARD THEN 'AUTO_MATCH'
            WHEN fz.FUZZY_SCORE >= $REVIEW_SCORE                    THEN 'REVIEW'
            ELSE 'NO_MATCH'
        END                                                         AS FUZZY_DECISION
    FROM fuzzy fz
    JOIN CURATED.MATCH_FEATURE mf ON mf.PAIR_ID = fz.PAIR_ID
    LEFT JOIN top_reasons tr      ON tr.PAIR_ID = fz.PAIR_ID
),

-- Production rules, checked in this order (first match wins).
with_path AS (
    SELECT
        fd.*,
        CASE
            -- a. Same real identifier = same entity. A company-number match only
            --    counts if the NZBNs do not conflict: two different NZBNs beat
            --    one matching number, so that case goes to rule b.
            --    v4: same legal entity/NZBN but a differently named registered
            --    charity (names share < AUTO_JACCARD of their words) is
            --    likely a branch; a human decides whether to merge. The same
            --    AUTO_JACCARD as the fuzzy gate, so there is ONE word-overlap
            --    threshold for every auto-merge.
            --    v5: a NULL Jaccard counts as 0, so it now fails the gate
            --    (before, NULL < 0.75 was not true and the gate was skipped).
            --    v5: an ID on more than ID_SHARED_MAX records is a parent /
            --    umbrella ID (see ID_SHARED_MAX): also REVIEW, same path and
            --    queue reason (SHARED_LEGAL_ENTITY). A missing count also
            --    fails, so the gate is never skipped.
            WHEN (fd.NZBN_EQ OR (fd.COMPANY_NO_EQ AND fd.NZBN_EQ IS NULL))
             AND (COALESCE(fd.NAME_TOKEN_JACCARD, 0) < $AUTO_JACCARD
                  OR NOT COALESCE(fd.ID_SHARED_COUNT <= $ID_SHARED_MAX, FALSE)) THEN 'ID_MATCH_NAME_DIFFERS'
            WHEN fd.NZBN_EQ
              OR (fd.COMPANY_NO_EQ AND fd.NZBN_EQ IS NULL)          THEN 'ID_MATCH'
            -- b. Both sides have an NZBN and they differ: strong evidence of two
            --    entities. A near-identical name may mean a mistyped NZBN, so
            --    a human checks those.
            WHEN NOT fd.NZBN_EQ
             AND fd.NAME_SCORE >= $ID_CONFLICT_REVIEW_NAME          THEN 'ID_CONFLICT_REVIEW'
            WHEN NOT fd.NZBN_EQ                                     THEN 'ID_CONFLICT'
            -- c. Members of one charity group share names/contacts on purpose;
            --    they are related, not the same entity.
            WHEN fd.SAME_PARENT_CHARITY                             THEN 'RELATED_GROUP_MEMBER'
            -- d. No identifier says anything: use the fuzzy result.
            ELSE 'FUZZY'
        END                                                         AS DECISION_PATH
    FROM fuzzy_decided fd
)

SELECT
    PAIR_ID, FUZZY_SCORE, FUZZY_DECISION, NAME_SCORE,
    HAS_SECOND_EVIDENCE, HAS_SHARED_CONTACT_ONLY, DECISION_PATH,
    CASE DECISION_PATH
        WHEN 'ID_MATCH'             THEN 100
        WHEN 'ID_CONFLICT'          THEN LEAST(FUZZY_SCORE, $ID_CONFLICT_CAP)
        WHEN 'RELATED_GROUP_MEMBER' THEN LEAST(FUZZY_SCORE, $ID_CONFLICT_CAP)
        ELSE FUZZY_SCORE
    END::NUMBER(5,2)                                                AS SCORE,
    CASE DECISION_PATH
        WHEN 'ID_MATCH'             THEN 'AUTO_MATCH'
        WHEN 'ID_MATCH_NAME_DIFFERS' THEN 'REVIEW'
        WHEN 'ID_CONFLICT_REVIEW'   THEN 'REVIEW'
        WHEN 'ID_CONFLICT'          THEN 'NO_MATCH'
        WHEN 'RELATED_GROUP_MEMBER' THEN 'NO_MATCH'
        ELSE FUZZY_DECISION
    END::VARCHAR                                                    AS DECISION,
    -- For rule-based paths the rule itself is the first reason.
    IFF(DECISION_PATH = 'FUZZY', REASONS, ARRAY_PREPEND(REASONS, DECISION_PATH))::ARRAY
                                                                    AS TOP_REASONS
FROM with_path;

-- -----------------------------------------------------------------------------
-- 4) CURATED.MATCH_DECISION: rebuild, one row per pair.
-- -----------------------------------------------------------------------------
TRUNCATE TABLE CURATED.MATCH_DECISION;

INSERT INTO CURATED.MATCH_DECISION (
    PAIR_ID, SCORE, DECISION, RULE_VERSION, TOP_REASONS, RUN_ID, DECIDED_AT,
    FUZZY_SCORE, FUZZY_DECISION, DECISION_PATH
)
SELECT
    PAIR_ID, SCORE, DECISION, $RULE_VERSION, TOP_REASONS, $RUN_ID,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    FUZZY_SCORE, FUZZY_DECISION, DECISION_PATH
FROM CURATED.TMP_PAIR_SCORE;

-- -----------------------------------------------------------------------------
-- 5) AUDIT.MATCH_EVIDENCE: the ledger behind every score. WEIGHT is the
--    effective weight (after rarity); identifier rows have WEIGHT and
--    CONTRIBUTION NULL because they drive rules, not the weighted sum.
-- -----------------------------------------------------------------------------
TRUNCATE TABLE AUDIT.MATCH_EVIDENCE;

INSERT INTO AUDIT.MATCH_EVIDENCE (
    PAIR_ID, FEATURE, LEFT_VALUE, RIGHT_VALUE, SIMILARITY, WEIGHT, CONTRIBUTION, RUN_ID
)
SELECT PAIR_ID, FEATURE, LEFT_VALUE, RIGHT_VALUE, SIMILARITY, EFF_WEIGHT, CONTRIBUTION, $RUN_ID
FROM CURATED.TMP_MATCH_EVIDENCE;

-- -----------------------------------------------------------------------------
-- 6) AUDIT.EXCEPTION_QUEUE: at most one row per pair.
--    - every production REVIEW pair;
--    - fuzzy NO_MATCH pairs with a very similar name whose only other
--      agreement is a heavily shared contact (weight 0). They are not matches
--      on the evidence we trust, but a human should confirm.
--    The SHARED_CONTACT_ONLY branch only takes NO_MATCH pairs, so a pair that
--    is already queued as REVIEW is never queued twice.
-- -----------------------------------------------------------------------------
TRUNCATE TABLE AUDIT.EXCEPTION_QUEUE;

INSERT INTO AUDIT.EXCEPTION_QUEUE (EXCEPTION_ID, PAIR_ID, RECORD_KEY, REASON_CODE, SCORE, STATUS, RUN_ID)
SELECT
    UUID_STRING(),
    PAIR_ID,
    NULL,
    CASE
        WHEN DECISION = 'REVIEW' AND DECISION_PATH = 'ID_CONFLICT_REVIEW' THEN 'ID_CONFLICT_HIGH_NAME'
        -- Same legal entity/NZBN but a differently named registered charity,
        -- or (v5) an ID shared by many records (parent/umbrella ID):
        -- likely a branch; a human decides whether to merge.
        WHEN DECISION = 'REVIEW' AND DECISION_PATH = 'ID_MATCH_NAME_DIFFERS' THEN 'SHARED_LEGAL_ENTITY'
        WHEN DECISION = 'REVIEW'                                         THEN 'BORDERLINE_SCORE'
        ELSE 'SHARED_CONTACT_ONLY'
    END,
    SCORE,
    'OPEN',
    $RUN_ID
FROM CURATED.TMP_PAIR_SCORE
WHERE DECISION = 'REVIEW'
   OR (DECISION_PATH = 'FUZZY'
       AND DECISION = 'NO_MATCH'
       AND NAME_SCORE >= $SHARED_CONTACT_NAME
       AND HAS_SHARED_CONTACT_ONLY);

-- -----------------------------------------------------------------------------
-- 7) Audit log row. SUCCESS only if every feature row got exactly one
--    decision (and there were pairs at all).
-- -----------------------------------------------------------------------------
INSERT INTO AUDIT.PIPELINE_RUN (RUN_ID, STEP, STARTED_AT, FINISHED_AT, ROWS_OUT, RULE_VERSION, STATUS, NOTES)
SELECT $RUN_ID, '06_matching',
       $STARTED_AT,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
       d.n, $RULE_VERSION,
       IFF(d.n = f.n AND d.n > 0, 'SUCCESS', 'FAIL'),
       'features=' || f.n || ', auto=' || d.auto_n || ', review=' || d.review_n
           || ', exceptions=' || e.n
FROM (SELECT COUNT(*) n,
             COUNT_IF(DECISION = 'AUTO_MATCH') auto_n,
             COUNT_IF(DECISION = 'REVIEW') review_n
      FROM CURATED.MATCH_DECISION) d,
     (SELECT COUNT(*) n FROM CURATED.MATCH_FEATURE) f,
     (SELECT COUNT(*) n FROM AUDIT.EXCEPTION_QUEUE) e;

-- -----------------------------------------------------------------------------
-- 8) Summary (last, so this result is what you see in Snowsight).
--    One (METRIC, VALUE) table. VALUES lists make a category with 0 rows still
--    show as 0. The 5 examples are the LOWEST-scoring fuzzy auto-matches, i.e.
--    the ones closest to the threshold and most worth checking by eye.
-- -----------------------------------------------------------------------------
SELECT METRIC, VALUE
FROM (
    SELECT 1 AS SORT_ORDER, 'decision_' || v.D AS METRIC, COUNT(d.PAIR_ID)::NUMBER(18,2) AS VALUE
    FROM (SELECT * FROM VALUES ('AUTO_MATCH'), ('REVIEW'), ('NO_MATCH') AS t(D)) v
    LEFT JOIN CURATED.MATCH_DECISION d ON d.DECISION = v.D
    GROUP BY v.D

    UNION ALL
    SELECT 2, 'path_' || v.P, COUNT(d.PAIR_ID)
    FROM (SELECT * FROM VALUES ('ID_MATCH'), ('ID_MATCH_NAME_DIFFERS'), ('ID_CONFLICT'),
                               ('ID_CONFLICT_REVIEW'), ('RELATED_GROUP_MEMBER'), ('FUZZY') AS t(P)) v
    LEFT JOIN CURATED.MATCH_DECISION d ON d.DECISION_PATH = v.P
    GROUP BY v.P

    UNION ALL
    SELECT 3, 'fuzzy_decision_' || v.D, COUNT(d.PAIR_ID)
    FROM (SELECT * FROM VALUES ('AUTO_MATCH'), ('REVIEW'), ('NO_MATCH') AS t(D)) v
    LEFT JOIN CURATED.MATCH_DECISION d ON d.FUZZY_DECISION = v.D
    GROUP BY v.D

    UNION ALL
    SELECT 4, 'exceptions_' || v.R, COUNT(e.EXCEPTION_ID)
    FROM (SELECT * FROM VALUES ('BORDERLINE_SCORE'), ('ID_CONFLICT_HIGH_NAME'),
                               ('SHARED_LEGAL_ENTITY'), ('SHARED_CONTACT_ONLY') AS t(R)) v
    LEFT JOIN AUDIT.EXCEPTION_QUEUE e ON e.REASON_CODE = v.R
    GROUP BY v.R

    UNION ALL
    SELECT 5, METRIC, VALUE
    FROM (
        SELECT COALESCE(l.NAME_RAW, l.NAME_CLEAN) || ' <-> ' || COALESCE(r.NAME_RAW, r.NAME_CLEAN) AS METRIC,
               d.SCORE AS VALUE
        FROM CURATED.MATCH_DECISION d
        JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = d.PAIR_ID
        JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
        JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
        WHERE d.DECISION_PATH = 'FUZZY'
          AND d.DECISION = 'AUTO_MATCH'
        ORDER BY d.SCORE, d.PAIR_ID
        LIMIT 5
    )

    -- v2: random samples, so a review sees typical pairs, not only the edge.
    -- A different sample on every run is intended.
    UNION ALL
    SELECT 6, METRIC, VALUE
    FROM (
        SELECT 'random_auto: ' || COALESCE(l.NAME_RAW, l.NAME_CLEAN) || ' <-> '
                               || COALESCE(r.NAME_RAW, r.NAME_CLEAN) AS METRIC,
               d.SCORE AS VALUE
        FROM CURATED.MATCH_DECISION d
        JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = d.PAIR_ID
        JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
        JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
        WHERE d.DECISION_PATH = 'FUZZY'
          AND d.DECISION = 'AUTO_MATCH'
        ORDER BY RANDOM()
        LIMIT 5
    )

    UNION ALL
    SELECT 7, METRIC, VALUE
    FROM (
        SELECT 'random_review: ' || COALESCE(l.NAME_RAW, l.NAME_CLEAN) || ' <-> '
                                 || COALESCE(r.NAME_RAW, r.NAME_CLEAN) AS METRIC,
               d.SCORE AS VALUE
        FROM CURATED.MATCH_DECISION d
        JOIN CURATED.CANDIDATE_PAIR p   ON p.PAIR_ID    = d.PAIR_ID
        JOIN STAGING.ORGANISATION_STD l ON l.RECORD_KEY = p.LEFT_KEY
        JOIN STAGING.ORGANISATION_STD r ON r.RECORD_KEY = p.RIGHT_KEY
        WHERE d.DECISION = 'REVIEW'
        ORDER BY RANDOM()
        LIMIT 5
    )
)
ORDER BY SORT_ORDER, METRIC;
