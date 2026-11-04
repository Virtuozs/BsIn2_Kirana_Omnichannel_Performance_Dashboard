"""Task 1: Data Profiling. Standalone entrypoint.

Usage:
    uv run python scripts/01_profile_data.py

Also importable by a future orchestrator:
    from scripts.lib.profiling import run_profiling
    run_profiling(con)   # con = an open duckdb connection to db/kirana.duckdb

Rerunning this script is safe: raw.* tables are rebuilt with
CREATE OR REPLACE, and the evidence CSVs/markdown are overwritten, not
appended to, so two runs against unchanged data produce byte-identical
output (only db/kirana.duckdb's _meta.run_log grows, by design).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import duckdb

from scripts.lib.paths import DB_PATH
from scripts.lib.profiling import run_profiling


def main() -> None:
    con = duckdb.connect(str(DB_PATH))
    try:
        summary = run_profiling(con)
        print(f"Profiled {summary['tables_profiled']} tables -> {summary['out_dir']}")
        for name, meta in summary["load_meta"].items():
            print(f"  raw.{name}: {meta['rows']} rows (source={meta['source_file']})")
    finally:
        con.close()


if __name__ == "__main__":
    main()
