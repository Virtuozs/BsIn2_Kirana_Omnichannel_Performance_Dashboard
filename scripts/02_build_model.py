"""Task 2: Data Preparation & Data Model. Standalone entrypoint.

Runs sql/01_load_raw.sql .. sql/05_reconciliation.sql in order against
db/kirana.duckdb, each as one DuckDB statement batch (DuckDB's Python
`execute` runs a whole script's statements in sequence when given the
full text). Logs one _meta.run_log row per layer (see scripts/lib/run_log.py)
-- same accountability pattern as scripts/01_profile_data.py (Task 1).

Usage:
    uv run python scripts/02_build_model.py

Idempotent: every table in sql/*.sql is CREATE OR REPLACE (facts/dims)
or an append-only log table (_meta.run_log, model.dq_test_results) by
design -- rerunning this script rebuilds raw/staging/model identically
and appends one more audit trail entry.
"""

import sys
import datetime as dt
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import duckdb

from scripts.lib.paths import DB_PATH, PROJECT_ROOT
from scripts.lib.run_log import log_step

SQL_DIR = PROJECT_ROOT / "sql"
LAYERS = [
    "01_load_raw.sql",
    "02_staging.sql",
    "03_star_schema.sql",
    "04_quality_tests.sql",
    "05_reconciliation.sql",
]


def main() -> None:
    con = duckdb.connect(str(DB_PATH))
    try:
        for layer in LAYERS:
            sql_path = SQL_DIR / layer
            started_at = dt.datetime.now()
            try:
                con.execute(sql_path.read_text(encoding="utf-8"))
                status = "OK"
                details = {"sql_file": str(sql_path.relative_to(PROJECT_ROOT))}
            except Exception as exc:
                status = "FAILED"
                details = {"sql_file": str(sql_path.relative_to(PROJECT_ROOT)), "error": str(exc)}
                log_step(con, step=f"task2_{layer}", status=status,
                          started_at=started_at, finished_at=dt.datetime.now(), details=details)
                raise
            finished_at = dt.datetime.now()
            log_step(con, step=f"task2_{layer}", status=status,
                      started_at=started_at, finished_at=finished_at, details=details)
            print(f"  [{status}] {layer} ({(finished_at - started_at).total_seconds():.1f}s)")

        print("\nTask 2 build complete. Quality test results:")
        print(con.execute("""
            SELECT test_id, classification, rows_failed, passed
            FROM model.dq_test_results
            WHERE run_ts = (SELECT max(run_ts) FROM model.dq_test_results)
            ORDER BY test_id
        """).fetchdf().to_string(index=False))

        print("\nReconciliation:")
        print(con.execute("SELECT layer, raw_rows, fact_rows, rows_dropped FROM model.reconciliation").fetchdf().to_string(index=False))
    finally:
        con.close()


if __name__ == "__main__":
    main()
