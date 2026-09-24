"""Static checks run by GitHub Actions (.github/workflows/ci.yml) and locally.

No Snowflake connection and no secrets: these checks only read the repository.
Run locally with:  python scripts/ci_checks.py
Exit code 0 = all checks pass.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Each pipeline step and the test suite that must exist for it.
STEP_TESTS = {
    "03": "test_standardisation.sql",
    "04": "test_candidates.sql",
    "05": "test_features.sql",
    "06": "test_matching.sql",
    "07": "test_golden_record.sql",
    "08": "test_evaluation.sql",
}

# Snowflake rules learned during the build (checked on SQL with comments removed).
SQL_RULES = [
    (re.compile(r"\bIS\s+(NOT\s+)?(TRUE|FALSE)\b", re.I),
     "Snowflake has no IS TRUE / IS FALSE: use = TRUE or COALESCE(x, FALSE)"),
    (re.compile(r"^\s*SET\s+\w+\s*=\s*[A-Z_][A-Z0-9_]*\s*\(", re.I | re.M),
     "SET cannot take a function call directly: use SET X = (SELECT ...)"),
]

# Files that must never be committed.
FORBIDDEN_TRACKED = re.compile(
    r"(\.p8$|\.pem$|(^|/)\.env$|(^|/)connections\.toml$|^data/(raw|clean)/)", re.I
)

failures = []


def fail(msg):
    failures.append(msg)
    print(f"FAIL  {msg}")


def strip_comments(sql):
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)   # block comments
    sql = re.sub(r"--[^\n]*", " ", sql)                 # line comments
    return sql


def check_tests_exist():
    for step, test in STEP_TESTS.items():
        if not list((ROOT / "sql").glob(f"{step}_*.sql")):
            fail(f"missing pipeline file sql/{step}_*.sql")
        test_path = ROOT / "tests" / "sql" / test
        if not test_path.exists():
            fail(f"step {step} has no test suite tests/sql/{test}")
        elif "failure_count" not in test_path.read_text(encoding="utf-8").lower():
            fail(f"tests/sql/{test} does not end with a failure_count summary")


def check_sql_rules():
    files = sorted((ROOT / "sql").rglob("*.sql")) + sorted((ROOT / "tests" / "sql").glob("*.sql"))
    for path in files:
        code = strip_comments(path.read_text(encoding="utf-8"))
        for pattern, why in SQL_RULES:
            for m in pattern.finditer(code):
                line = code[: m.start()].count("\n") + 1
                fail(f"{path.relative_to(ROOT)}:{line}: {why}")
    print(f"      checked {len(files)} SQL files for Snowflake rules")


def check_python_compiles():
    for path in sorted((ROOT / "scripts").glob("*.py")):
        try:
            compile(path.read_text(encoding="utf-8"), str(path), "exec")
        except SyntaxError as e:
            fail(f"{path.relative_to(ROOT)} does not compile: {e}")


def check_no_secrets_tracked():
    try:
        tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                                 text=True, check=True).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError):
        print("      git not available: skipped tracked-file check")
        return
    for f in tracked:
        if FORBIDDEN_TRACKED.search(f):
            fail(f"sensitive or data file is tracked in git: {f}")


if __name__ == "__main__":
    for name, check in [("pipeline steps have test suites", check_tests_exist),
                        ("Snowflake SQL rules", check_sql_rules),
                        ("Python scripts compile", check_python_compiles),
                        ("no keys, .env or full datasets tracked", check_no_secrets_tracked)]:
        print(f"CHECK {name}")
        check()
    if failures:
        print(f"\n{len(failures)} check(s) failed")
        sys.exit(1)
    print("\nAll checks passed")
