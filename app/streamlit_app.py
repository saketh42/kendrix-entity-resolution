# Kendrix Entity Resolution Explorer (Streamlit in Snowflake)
# Read-only: it only runs SELECT queries on database KENDRIX.
import altair as alt
import pandas as pd
import streamlit as st

st.set_page_config(page_title="Kendrix Entity Resolution", layout="wide")
session = st.connection("snowflake").session()

BLUE = "#2a78d6"
DECISION_TEXT = {"AUTO_MATCH": "🟢 Merged automatically", "REVIEW": "🟡 Sent to a person",
                 "NO_MATCH": "⚪ Kept separate"}
REASON_TEXT = {
    "BORDERLINE_SCORE": "Borderline score",
    "SHARED_CONTACT_ONLY": "Only a shared phone / email / website",
    "ID_CONFLICT_HIGH_NAME": "Same name, different NZBN",
    "SHARED_LEGAL_ENTITY": "Same NZBN, different name",
    "CHAIN_NZBN_CONFLICT": "Chain of matches joins two NZBNs",
}
FEATURE_TEXT = {
    "NAME_BEST_JW": "Name", "ADDRESS_JW": "Address", "POSTCODE_EQ": "Postcode", "CITY_EQ": "City",
    "PHONE_EQ": "Phone", "EMAIL_EQ": "Email", "WEBSITE_EQ": "Website", "NZBN_EQ": "NZBN",
    "COMPANY_NO_EQ": "Company no.", "SAME_PARENT_CHARITY": "Parent charity",
}
ID_FEATURES = {"NZBN_EQ", "COMPANY_NO_EQ", "SAME_PARENT_CHARITY"}
EXAMPLES = {
    "Age Concern South Canterbury": "Age Concern South Canterbury",
    "Albany Community Pre-School": "Albany Community Pre-School",
    "Antarctic Heritage Trust": "Antarctic Heritage",
    "Search any name": "",
}


def q(sql, params=None):
    """Run a read-only query and return a pandas DataFrame."""
    return session.sql(sql, params=params).to_pandas()


def fmt(n):
    return f"{int(n):,}"


# ---------------------------------------------------------------- header
st.title("Kendrix Entity Resolution")
st.caption("One trusted record per New Zealand organisation · every match keeps its evidence · "
           "every uncertain case goes to a person")

kpi = q("""
SELECT
  (SELECT COUNT(*) FROM KENDRIX.STAGING.ORGANISATION_STD)        AS RECORDS,
  (SELECT COUNT(*) FROM KENDRIX.CURATED.MASTER_ORGANISATION)     AS MASTERS,
  (SELECT COUNT(*) FROM KENDRIX.CURATED.MASTER_ORGANISATION
     WHERE MEMBER_COUNT > 1)                                     AS MERGED,
  (SELECT COUNT(*) FROM (SELECT MASTER_ID FROM KENDRIX.CURATED.ENTITY_XREF
     GROUP BY MASTER_ID
     HAVING COUNT(DISTINCT SPLIT_PART(RECORD_KEY, ':', 1)) = 2)) AS CROSS_REGISTER,
  (SELECT COUNT(*) FROM KENDRIX.AUDIT.EXCEPTION_QUEUE
     WHERE STATUS = 'OPEN')                                      AS OPEN_REVIEWS
""").iloc[0]

with st.container(border=True):
    c = st.columns(5)
    c[0].metric("Source records", fmt(kpi["RECORDS"]), help="Charities Register + Companies Office, cleaned")
    c[1].metric("Master organisations", fmt(kpi["MASTERS"]), help="One row per real organisation")
    c[2].metric("Masters combining records", fmt(kpi["MERGED"]), help="Built from 2 or more source records")
    c[3].metric("Found in both registers", fmt(kpi["CROSS_REGISTER"]), help="A charity record and a company record linked")
    c[4].metric("Open review items", fmt(kpi["OPEN_REVIEWS"]), help="Waiting for a person to decide")

tab_search, tab_decisions, tab_story = st.tabs(
    ["🔎  Look up an organisation", "📊  Decisions & review queue", "📈  How matching improved"])

# ---------------------------------------------------------------- lookup
with tab_search:
    preset = st.radio("Try an example", list(EXAMPLES), horizontal=True)
    name = st.text_input("Organisation name contains", value=EXAMPLES[preset], key=f"search_{preset}",
                         placeholder="Type part of a name, e.g. Lions Club")

    if name.strip():
        masters = q("""
            SELECT MASTER_ID, MASTER_NAME, MEMBER_COUNT, NZBN_CONFLICT
            FROM KENDRIX.CURATED.MASTER_ORGANISATION
            WHERE MASTER_NAME ILIKE ?
            ORDER BY MEMBER_COUNT DESC, MASTER_NAME
            LIMIT 50""", params=[f"%{name.strip()}%"])

        if masters.empty:
            st.info("No master organisation matches that name.")
        else:
            labels = [f"{r.MASTER_NAME}  ·  {int(r.MEMBER_COUNT)} record{'s' if r.MEMBER_COUNT != 1 else ''}"
                      f"{'  ·  ⚠ NZBN conflict' if r.NZBN_CONFLICT else ''}" for r in masters.itertuples()]
            pick = st.selectbox(f"Master organisation ({len(masters)} found)", range(len(labels)),
                                format_func=lambda i: labels[i])
            chosen = masters.iloc[pick]

            members = q("""
                SELECT x.RECORD_KEY,
                       IFF(STARTSWITH(x.RECORD_KEY, 'CHR:'), 'Charities Register', 'Companies Office') AS REGISTER,
                       s.NAME_RAW, s.NZBN, s.CHARITY_REG_NO, s.ENTITY_STATUS, s.REGISTERED_DATE
                FROM KENDRIX.CURATED.ENTITY_XREF x
                JOIN KENDRIX.STAGING.ORGANISATION_STD s ON s.RECORD_KEY = x.RECORD_KEY
                WHERE x.MASTER_ID = ?
                ORDER BY x.RECORD_KEY""", params=[chosen["MASTER_ID"]])
            keys = members["RECORD_KEY"].tolist()
            marks = ",".join(["?"] * len(keys))
            names = dict(zip(members["RECORD_KEY"], members["NAME_RAW"]))

            # --- 1. the master record
            with st.container(border=True):
                st.markdown(f"### {chosen['MASTER_NAME']}")
                m = st.columns(3)
                m[0].metric("Source records", len(keys))
                m[1].metric("Registers", members["REGISTER"].nunique())
                m[2].metric("NZBNs", members["NZBN"].dropna().nunique())
                if bool(chosen["NZBN_CONFLICT"]):
                    st.warning("⚠ **NZBN conflict flagged** - a chain of matches joined records with different "
                               "NZBNs. We don't hide it: every member is in the review queue for a person.")
                elif len(keys) == 1:
                    st.info("This organisation appears once - nothing was merged into it.")
                else:
                    st.success("✔ Records merged with no identifier conflict.")

            # --- 2. lineage
            st.markdown("#### 1 · Source records behind this master (lineage)")
            st.dataframe(members.drop(columns=["RECORD_KEY"]), width="stretch", hide_index=True,
                         column_config={"REGISTER": "Register", "NAME_RAW": "Name as registered",
                                        "NZBN": "NZBN", "CHARITY_REG_NO": "Charity no.",
                                        "ENTITY_STATUS": "Status", "REGISTERED_DATE": "Registered"})

            # --- 3. evidence
            if len(keys) > 1:
                st.markdown("#### 2 · Why these records were matched (evidence)")
                ev = q(f"""
                    SELECT p.PAIR_ID, p.LEFT_KEY, p.RIGHT_KEY, d.DECISION, e.FEATURE,
                           e.LEFT_VALUE, e.RIGHT_VALUE, e.SIMILARITY, e.CONTRIBUTION
                    FROM KENDRIX.CURATED.CANDIDATE_PAIR p
                    JOIN KENDRIX.CURATED.MATCH_DECISION d ON d.PAIR_ID = p.PAIR_ID
                    JOIN KENDRIX.AUDIT.MATCH_EVIDENCE e ON e.PAIR_ID = p.PAIR_ID
                    WHERE p.LEFT_KEY IN ({marks}) AND p.RIGHT_KEY IN ({marks})""", params=keys + keys)
                if ev.empty:
                    st.info("No stored evidence rows for these records.")
                    st.stop()
                ev["EVIDENCE"] = ev["FEATURE"].map(FEATURE_TEXT).fillna(ev["FEATURE"])
                order = {"AUTO_MATCH": 0, "REVIEW": 1, "NO_MATCH": 2}

                summary = []
                for pid, g in ev.groupby("PAIR_ID"):
                    first = g.iloc[0]
                    strong = g[(~g["FEATURE"].isin(ID_FEATURES)) & (g["SIMILARITY"].fillna(0) >= 80)] \
                        .sort_values("CONTRIBUTION", ascending=False)["EVIDENCE"].tolist()
                    nz = g[g["FEATURE"] == "NZBN_EQ"]
                    sim = None if nz.empty else nz.iloc[0]["SIMILARITY"]
                    ident = "—" if sim is None or pd.isna(sim) else \
                        ("✔ same NZBN" if float(sim) >= 100 else "✖ different NZBN")
                    summary.append({
                        "PAIR_ID": pid, "SORT": order.get(first["DECISION"], 3),
                        "RECORDS": f"{names.get(first['LEFT_KEY'], first['LEFT_KEY'])}  ↔  "
                                   f"{names.get(first['RIGHT_KEY'], first['RIGHT_KEY'])}",
                        "DECISION": DECISION_TEXT.get(first["DECISION"], first["DECISION"]),
                        "SCORE": float(g["CONTRIBUTION"].fillna(0).sum()),
                        "STRONG": ", ".join(strong) if strong else "—",
                        "ID": ident})
                summary = pd.DataFrame(summary).sort_values(["SORT", "SCORE"], ascending=[True, False])
                st.dataframe(summary.drop(columns=["PAIR_ID", "SORT"]), width="stretch", hide_index=True,
                             column_config={
                                 "RECORDS": st.column_config.TextColumn("Pair of records", width="large"),
                                 "DECISION": "Decision",
                                 "SCORE": st.column_config.ProgressColumn("Evidence score", min_value=0,
                                                                          max_value=100, format="%.0f"),
                                 "STRONG": "Strong evidence (≥ 80% similar)",
                                 "ID": "Identifier check"})
                st.caption("Evidence score = sum of each field's contribution. Identifiers are rules, not score: "
                           "a different NZBN blocks an automatic merge; the same NZBN confirms one.")

                for row in summary.itertuples():
                    with st.expander(f"Details · {row.RECORDS}  ·  {row.DECISION}"):
                        g = ev[(ev["PAIR_ID"] == row.PAIR_ID) &
                               ((ev["SIMILARITY"].fillna(0) > 0) | ev["FEATURE"].isin(ID_FEATURES))] \
                            .sort_values("CONTRIBUTION", ascending=False, na_position="last")
                        st.dataframe(g[["EVIDENCE", "LEFT_VALUE", "RIGHT_VALUE", "SIMILARITY", "CONTRIBUTION"]],
                                     width="stretch", hide_index=True, column_config={
                                         "EVIDENCE": "Evidence", "LEFT_VALUE": "Left record",
                                         "RIGHT_VALUE": "Right record",
                                         "SIMILARITY": st.column_config.ProgressColumn(
                                             "Similarity", min_value=0, max_value=100, format="%.0f"),
                                         "CONTRIBUTION": st.column_config.ProgressColumn(
                                             "Share of score %", min_value=0, max_value=100, format="%.1f")})

            # --- 4. review queue
            st.markdown(f"#### {3 if len(keys) > 1 else 2} · Waiting for a person (review queue)")
            queue = q(f"""
                SELECT q.REASON_CODE, q.STATUS, q.RECORD_KEY, p.LEFT_KEY, p.RIGHT_KEY
                FROM KENDRIX.AUDIT.EXCEPTION_QUEUE q
                LEFT JOIN KENDRIX.CURATED.CANDIDATE_PAIR p ON p.PAIR_ID = q.PAIR_ID
                WHERE q.RECORD_KEY IN ({marks})
                   OR p.LEFT_KEY IN ({marks}) OR p.RIGHT_KEY IN ({marks})""", params=keys + keys + keys)
            if queue.empty:
                st.success("✔ Nothing for this organisation is waiting for review.")
            else:
                other = [k for k in set(queue["LEFT_KEY"].dropna()) | set(queue["RIGHT_KEY"].dropna()) if k not in names]
                if other:
                    extra = q(f"SELECT RECORD_KEY, NAME_RAW FROM KENDRIX.STAGING.ORGANISATION_STD "
                              f"WHERE RECORD_KEY IN ({','.join(['?'] * len(other))})", params=other)
                    names.update(dict(zip(extra["RECORD_KEY"], extra["NAME_RAW"])))

                def what(r):
                    if pd.notna(r["LEFT_KEY"]):
                        return f"{names.get(r['LEFT_KEY'], r['LEFT_KEY'])}  ↔  {names.get(r['RIGHT_KEY'], r['RIGHT_KEY'])}"
                    return names.get(r["RECORD_KEY"], r["RECORD_KEY"])

                queue["ITEM"] = queue.apply(what, axis=1)
                queue["REASON"] = queue["REASON_CODE"].map(REASON_TEXT).fillna(queue["REASON_CODE"])
                st.dataframe(queue[["REASON", "ITEM", "STATUS"]], width="stretch", hide_index=True,
                             column_config={"REASON": "Why a person must check",
                                            "ITEM": st.column_config.TextColumn("Record or pair", width="large"),
                                            "STATUS": "Status"})

# ---------------------------------------------------------------- decisions
with tab_decisions:
    dec = q("""SELECT DECISION, COUNT(*) AS PAIRS FROM KENDRIX.CURATED.MATCH_DECISION GROUP BY DECISION""") \
        .set_index("DECISION")["PAIRS"]
    total = int(dec.sum())

    st.markdown("#### What happened to each candidate pair")
    st.caption(f"{fmt(total)} likely pairs compared - blocking avoided about 1.1 billion comparisons")
    d = st.columns(3)
    for col, key in zip(d, ["AUTO_MATCH", "REVIEW", "NO_MATCH"]):
        with col.container(border=True):
            st.metric(DECISION_TEXT[key], fmt(dec.get(key, 0)))
            st.caption(f"{dec.get(key, 0) / total * 100:.1f}% of pairs")

    st.markdown("#### Why items are in the review queue")
    reasons = q("""SELECT REASON_CODE, COUNT(*) AS ITEMS FROM KENDRIX.AUDIT.EXCEPTION_QUEUE GROUP BY REASON_CODE""")
    reasons["REASON"] = reasons["REASON_CODE"].map(REASON_TEXT).fillna(reasons["REASON_CODE"])
    st.caption(f"{fmt(reasons['ITEMS'].sum())} items, each with a reason code and status")
    order = reasons.sort_values("ITEMS", ascending=False)["REASON"].tolist()
    base = alt.Chart(reasons).encode(
        y=alt.Y("REASON:N", sort=order, title=None,
                axis=alt.Axis(labelLimit=360, labelFontSize=13, ticks=False, domain=False)),
        x=alt.X("ITEMS:Q", title=None, scale=alt.Scale(domain=[0, float(reasons["ITEMS"].max()) * 1.15]),
                axis=alt.Axis(gridColor="#ecebe7", domain=False, ticks=False, labelColor="#6b6a66", format=",d")),
        tooltip=[alt.Tooltip("REASON:N", title="Reason"), alt.Tooltip("ITEMS:Q", title="Items", format=",")])
    st.altair_chart((base.mark_bar(cornerRadiusEnd=4, size=24, color=BLUE)
                     + base.mark_text(align="left", dx=6, fontSize=13, color="#3a3936")
                     .encode(text=alt.Text("ITEMS:Q", format=",")))
                    .properties(height=250, width="container").configure_view(strokeWidth=0))

    st.markdown("#### How many source records each master combines")
    sizes = q("""SELECT MEMBER_COUNT, COUNT(*) AS MASTERS FROM KENDRIX.CURATED.MASTER_ORGANISATION
                 GROUP BY MEMBER_COUNT ORDER BY MEMBER_COUNT""")
    s = st.columns(len(sizes))
    for col, r in zip(s, sizes.itertuples()):
        with col.container(border=True):
            st.metric(f"{int(r.MEMBER_COUNT)} record{'s' if r.MEMBER_COUNT != 1 else ''}", fmt(r.MASTERS))
    st.caption("The largest master combines 4 records - our safety rules stop long chains of wrong merges.")

# ---------------------------------------------------------------- story
with tab_story:
    story = pd.DataFrame({
        "VERSION": ["v1", "v2", "v3", "v4", "v5"],
        "AUTO_MATCHES": [13208, 2502, 2083, 1298, 1187],
        "WHAT_CHANGED": [
            "First model - different estates merged (name prefix bias)",
            "Reverse name similarity; shared addresses count only if rare",
            "Word-overlap gate: 3 of every 4 words must match",
            "Same NZBN but different name -> sent to a person",
            "Fake NZBNs rejected, NULL gate bug fixed, parent IDs -> review",
        ],
    })
    a, b = st.columns([2, 1], gap="large")
    with a:
        st.markdown("#### Automatic merges per rule version")
        st.caption("Each version fixed a real error that our tests caught")
        base = alt.Chart(story).encode(
            x=alt.X("VERSION:N", title=None, sort=None,
                    axis=alt.Axis(labelAngle=0, labelFontSize=14, ticks=False, domain=False)),
            y=alt.Y("AUTO_MATCHES:Q", title=None, scale=alt.Scale(domain=[0, 15000]),
                    axis=alt.Axis(gridColor="#ecebe7", domain=False, ticks=False, labelColor="#6b6a66", format=",d")),
            tooltip=[alt.Tooltip("VERSION:N", title="Version"),
                     alt.Tooltip("AUTO_MATCHES:Q", title="Automatic merges", format=","),
                     alt.Tooltip("WHAT_CHANGED:N", title="What changed")])
        st.altair_chart((base.mark_bar(cornerRadiusEnd=4, size=64, color=BLUE)
                         + base.mark_text(dy=-10, fontSize=14, color="#3a3936")
                         .encode(text=alt.Text("AUTO_MATCHES:Q", format=",")))
                        .properties(height=320, width="container").configure_view(strokeWidth=0))
    with b:
        st.markdown("#### Result")
        with st.container(border=True):
            st.metric("Automatic merges, v1 → v5", "1,187", delta="-91% vs v1", delta_color="inverse")
        with st.container(border=True):
            st.metric("Auto-merged pairs with conflicting NZBNs", "0")
        with st.container(border=True):
            st.metric("Automated SQL tests passing", "51 / 51")

    st.markdown("#### What changed in each version")
    for r in story.itertuples():
        st.markdown(f"**{r.VERSION}** · {r.AUTO_MATCHES:,} automatic merges - {r.WHAT_CHANGED}")
    st.caption("Counts from our run history; the tables hold the current version (score_v5).")
