"""Convert the raw source files in data/raw/ into clean CSVs in data/clean/.

Outputs (one CSV per source, ready to load into KENDRIX.RAW):
    charities_organisations.csv  - byte-for-byte copy of the raw charities CSV
    companies_office.csv         - both Companies Office .xls exports stacked
    ird_donee.csv                - IRD donee list (optional source)

Run from anywhere:  python scripts/convert_sources.py
"""

import shutil
from pathlib import Path

import pandas as pd

REPO_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = REPO_ROOT / "data" / "raw"
CLEAN_DIR = REPO_ROOT / "data" / "clean"

COMPANIES_HEADER_CELL = "Business Name"
COMPANIES_COLUMNS = [
    "BUSINESS_NAME",
    "NZBN",
    "REGISTRATION_DATE",
    "ENTITY_TYPE",
    "ACT",
    "TRADING_AS",
    "PHYSICAL_ADDRESS",
    "PREVIOUSLY_KNOWN_AS",
    "PREVIOUSLY_TRADING_AS",
    "STATUS",  # unlabelled in the export
    "STATUS_DATE",  # unlabelled in the export
]
DONEE_COLUMNS = ["ORGANISATION_NAME", "CEASED_AS_DONEE"]


def find_one(pattern: str) -> Path:
    """Return the first file in data/raw/ matching pattern, or fail clearly."""
    matches = sorted(RAW_DIR.glob(pattern))
    if not matches:
        raise FileNotFoundError(f"No file matching {pattern!r} in {RAW_DIR}")
    return matches[0]


def write_csv(df: pd.DataFrame, name: str) -> Path:
    """Write df to data/clean/<name> as UTF-8 without the pandas index."""
    out_path = CLEAN_DIR / name
    df.to_csv(out_path, index=False, encoding="utf-8")
    return out_path


def convert_charities() -> tuple[int, Path]:
    """Copy the charities CSV unchanged and return (row count, output path).

    A plain file copy keeps the CRLF line endings and quoted line breaks exactly
    as received. Rows are counted by parsing the CSV, because counting lines
    would over-count the records with embedded line breaks.
    """
    src = RAW_DIR / "charities_organisations.csv"
    out_path = CLEAN_DIR / src.name
    shutil.copyfile(src, out_path)
    rows = len(pd.read_csv(out_path, dtype=str, encoding="utf-8"))
    return rows, out_path


def read_companies_export(path: Path) -> pd.DataFrame:
    """Read one Companies Office .xls export into a DataFrame with named columns.

    The export has junk search-criteria rows above the real header, so we look
    for the row whose first cell is "Business Name" instead of trusting a
    fixed offset.
    """
    sheet = pd.read_excel(path, header=None, dtype=str, engine="xlrd")
    first_col = sheet.iloc[:, 0].fillna("").str.strip()
    header_rows = sheet.index[first_col == COMPANIES_HEADER_CELL]
    if len(header_rows) == 0:
        raise ValueError(f"No {COMPANIES_HEADER_CELL!r} header row in {path.name}")

    header_pos = sheet.index.get_loc(header_rows[0])
    data = sheet.iloc[header_pos + 1 :, : len(COMPANIES_COLUMNS)].copy()
    data.columns = COMPANIES_COLUMNS
    data["EXPORT_FILE"] = path.name
    return data


def convert_companies() -> tuple[int, Path]:
    """Stack every export-*.xls file and write companies_office.csv.

    Only rows without an NZBN are dropped (spacer/footer rows). Rows without a
    business name are kept, because sole traders legitimately have only a
    Trading As name. Duplicates across the two overlapping searches are kept
    on purpose: RAW stores what was received and de-duplication happens later.
    """
    exports = sorted(RAW_DIR.glob("export-*.xls"))
    if not exports:
        raise FileNotFoundError(f"No export-*.xls files in {RAW_DIR}")

    combined = pd.concat([read_companies_export(p) for p in exports], ignore_index=True)
    has_nzbn = combined["NZBN"].fillna("").str.strip() != ""
    combined = combined[has_nzbn]
    return len(combined), write_csv(combined, "companies_office.csv")


def convert_donee() -> tuple[int, Path]:
    """Read the first sheet of the IRD donee workbook and write ird_donee.csv."""
    src = find_one("Donee*.xlsx")
    donee = pd.read_excel(src, sheet_name=0, dtype=str, engine="openpyxl")
    donee = donee.iloc[:, : len(DONEE_COLUMNS)]
    donee.columns = DONEE_COLUMNS
    return len(donee), write_csv(donee, "ird_donee.csv")


def main() -> None:
    """Run every conversion and print row counts."""
    CLEAN_DIR.mkdir(parents=True, exist_ok=True)
    for name, convert in [
        ("charities", convert_charities),
        ("companies_office", convert_companies),
        ("ird_donee", convert_donee),
    ]:
        rows, out_path = convert()
        print(f"{name}: {rows:,} rows -> {out_path.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
