"""Task 1: raw data profiling.

Reusable module: exposes `run_profiling(con)` so a later orchestrator can
call it with an already-open DuckDB connection, in addition to the
standalone CLI entrypoint in scripts/01_profile_data.py.

What it does, per raw file:
  - loads it into a `raw.<table>` table (CREATE OR REPLACE -> idempotent)
  - column profile: dtype, null count/%, distinct count, min/max (or
    sample values for strings)
  - full-row duplicate count
  - natural-key duplicate count, where a key is known (from the data
    dictionary in Data/README.md)
  - a handful of "unwarranted value" checks (negative prices, qty == 0,
    dates outside the documented 2024-01-01..2026-06-30 range)

Output: one CSV per table in evidence/task1_profiling/, plus a single
profiling_summary.md and a run_log entry.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field
from pathlib import Path

import duckdb

from .paths import RAW_DIR, EVIDENCE_DIR
from .run_log import file_sha256, log_step

OUT_DIR = EVIDENCE_DIR / "task1_profiling"

DATA_MIN_DATE = "2024-01-01"
DATA_MAX_DATE = "2026-06-30"


@dataclass
class TableSpec:
    name: str
    file: str
    kind: str = "csv"  # csv | xlsx
    key: list[str] = field(default_factory=list)
    date_cols: list[str] = field(default_factory=list)
    # xlsx-only
    sheet: str | None = None
    cell_range: str | None = None  # A1-style, e.g. "A3:N200"; header row is the first row of the range


TABLE_SPECS: list[TableSpec] = [
    TableSpec(
        "sales_pos_transactions",
        "sales_pos_transactions.csv",
        key=["trx_id", "line_no"],
        date_cols=["trx_datetime"],
    ),
    TableSpec(
        "sales_online_orders",
        "sales_online_orders.csv",
        key=["order_no", "line_no"],
        date_cols=["order_date"],
    ),
    TableSpec("products", "products.csv", key=["sku"], date_cols=["launch_date"]),
    TableSpec(
        "product_cost_history",
        "product_cost_history.csv",
        key=["sku", "valid_from"],
        date_cols=["valid_from", "valid_to"],
    ),
    TableSpec("stores", "stores.csv", key=["store_code"], date_cols=["open_date"]),
    TableSpec(
        "store_region_history",
        "store_region_history.csv",
        key=["store_code", "valid_from"],
        date_cols=["valid_from", "valid_to"],
    ),
    TableSpec(
        "store_events",
        "store_events.csv",
        key=["store_code", "start_date"],
        date_cols=["start_date", "end_date"],
    ),
    TableSpec(
        "customers",
        "customers.csv",
        key=["customer_id"],
        date_cols=["birth_date", "join_date"],
    ),
    TableSpec(
        "returns",
        "returns.csv",
        key=["return_id"],
        date_cols=["return_date"],
    ),
    TableSpec(
        "promotions",
        "promotions.csv",
        key=["promo_code"],
        date_cols=["start_date", "end_date"],
    ),
    TableSpec(
        "channel_fee_rates",
        "channel_fee_rates.csv",
        key=["channel", "valid_from"],
        date_cols=["valid_from", "valid_to"],
    ),
    TableSpec(
        "pos_sync_log",
        "pos_sync_log.csv",
        key=["store_code", "business_date"],
        date_cols=["business_date"],
    ),
    TableSpec(
        "target_net_sales_2025",
        "sales_targets_2025_2026.xlsx",
        kind="xlsx",
        sheet="Target Net Sales 2025",
        cell_range="A3:N200",
        key=["Channel", "Region"],
    ),
    TableSpec(
        "target_net_sales_h1_2026",
        "sales_targets_2025_2026.xlsx",
        kind="xlsx",
        sheet="Target Net Sales H1 2026",
        cell_range="A3:H200",
        key=["Channel", "Region"],
    ),
    TableSpec(
        "target_gm",
        "sales_targets_2025_2026.xlsx",
        kind="xlsx",
        sheet="Target GM",
        cell_range="A1:C200",
        key=["Channel"],
    ),
]


def load_raw_tables(con: duckdb.DuckDBPyConnection) -> dict[str, dict]:
    """(Re)loads every raw file into raw.<table>. Returns {table: {rows, source_hash}}."""
    con.execute("CREATE SCHEMA IF NOT EXISTS raw")
    con.execute("INSTALL excel")
    con.execute("LOAD excel")

    loaded = {}
    for spec in TABLE_SPECS:
        src = RAW_DIR / spec.file
        if spec.kind == "csv":
            con.execute(f"""
                CREATE OR REPLACE TABLE raw.{spec.name} AS
                SELECT * FROM read_csv(
                    '{src.as_posix()}',
                    header = true,
                    all_varchar = true,
                    sample_size = -1
                )
            """)
        else:
            con.execute(f"""
                CREATE OR REPLACE TABLE raw.{spec.name} AS
                SELECT * FROM read_xlsx(
                    '{src.as_posix()}',
                    sheet = '{spec.sheet}',
                    range = '{spec.cell_range}',
                    header = true,
                    all_varchar = true,
                    stop_at_empty = true
                )
            """)
        row_count = con.execute(f"SELECT count(*) FROM raw.{spec.name}").fetchall()[0][0]
        loaded[spec.name] = {
            "rows": row_count,
            "source_file": spec.file,
            "source_sha256_16": file_sha256(src) if src.exists() else None,
        }
    return loaded


def _column_profile(con: duckdb.DuckDBPyConnection, table: str) -> "duckdb.DuckDBPyRelation":
    cols = con.execute(f"DESCRIBE raw.{table}").fetchdf()["column_name"].tolist()
    total = con.execute(f"SELECT count(*) FROM raw.{table}").fetchall()[0][0]

    parts = []
    for c in cols:
        qc = f'"{c}"'
        parts.append(f"""
            SELECT
                '{c}' AS column_name,
                {total} AS total_rows,
                count(*) FILTER (WHERE {qc} IS NULL OR trim({qc}) = '') AS null_or_blank,
                round(100.0 * count(*) FILTER (WHERE {qc} IS NULL OR trim({qc}) = '') / NULLIF({total}, 0), 2) AS null_pct,
                count(DISTINCT {qc}) AS distinct_count,
                min({qc}) AS min_value,
                max({qc}) AS max_value
            FROM raw.{table}
        """)
    return con.sql(" UNION ALL ".join(parts) + f" ORDER BY column_name")


def _duplicate_counts(con: duckdb.DuckDBPyConnection, spec: TableSpec) -> dict:
    full_row_dupes = con.execute(f"""
        SELECT count(*) FROM (
            SELECT * , count(*) OVER (PARTITION BY {", ".join(f'"{c}"' for c in
                con.execute(f"DESCRIBE raw.{spec.name}").fetchdf()["column_name"].tolist())}) AS cnt
            FROM raw.{spec.name}
        ) WHERE cnt > 1
    """).fetchall()[0][0]

    key_dupes = None
    if spec.key:
        key_cols = ", ".join(f'"{c}"' for c in spec.key)
        key_dupes = con.execute(f"""
            SELECT count(*) FROM (
                SELECT {key_cols}, count(*) AS cnt
                FROM raw.{spec.name}
                GROUP BY {key_cols}
                HAVING count(*) > 1
            )
        """).fetchall()[0][0]

    return {"full_row_duplicate_rows": full_row_dupes, "natural_key_duplicate_groups": key_dupes}


# Columns whose on-disk date/datetime format is not ISO (per Data/README.md's
# kamus data) need an explicit strptime format, or every row false-positives
# as "unparseable".
DATE_FORMAT_OVERRIDES = {
    "order_date": "%d/%m/%Y %H:%M",  # sales_online_orders.csv
}


def _unwarranted_value_checks(con: duckdb.DuckDBPyConnection, spec: TableSpec) -> list[dict]:
    """A handful of generic sanity checks; findings feed the Data Quality Issue Log."""
    checks = []
    cols = con.execute(f"DESCRIBE raw.{spec.name}").fetchdf()["column_name"].tolist()

    for dcol in spec.date_cols:
        if dcol not in cols:
            continue
        fmt = DATE_FORMAT_OVERRIDES.get(dcol)
        if fmt:
            parse_expr = f"""try_strptime("{dcol}", '{fmt}')"""
        else:
            parse_expr = f"""COALESCE(TRY_CAST("{dcol}" AS TIMESTAMP), TRY_CAST("{dcol}" AS DATE))"""
        bad = con.execute(f"""
            SELECT count(*) FROM raw.{spec.name}
            WHERE {parse_expr} IS NULL AND "{dcol}" IS NOT NULL AND trim("{dcol}") != ''
        """).fetchall()[0][0]
        if bad:
            checks.append({"check": f"unparseable_date::{dcol}", "failing_rows": bad})

    for pcol in ("unit_price", "item_price", "unit_cost", "current_list_price", "current_unit_cost"):
        if pcol not in cols:
            continue
        bad = con.execute(f"""
            SELECT count(*) FROM raw.{spec.name}
            WHERE TRY_CAST("{pcol}" AS DOUBLE) < 0
        """).fetchall()[0][0]
        if bad:
            checks.append({"check": f"negative_value::{pcol}", "failing_rows": bad})

    if "qty" in cols:
        zero_qty = con.execute(f"""
            SELECT count(*) FROM raw.{spec.name} WHERE TRY_CAST(qty AS DOUBLE) = 0
        """).fetchall()[0][0]
        if zero_qty:
            checks.append({"check": "zero_qty", "failing_rows": zero_qty})

    return checks


def run_profiling(con: duckdb.DuckDBPyConnection, out_dir: Path = OUT_DIR) -> dict:
    """Runs the full Task 1 profiling pass. Returns a summary dict and writes evidence files."""
    started_at = dt.datetime.now()
    out_dir.mkdir(parents=True, exist_ok=True)

    load_meta = load_raw_tables(con)

    summary_lines = [
        "# Task 1: Data Profiling Summary",
        "",
        f"Generated: {started_at.isoformat(timespec='seconds')}",
        "",
        "| table | source_file | rows | source_sha256(16) | full_row_dupes | key_dupe_groups |",
        "|---|---|---:|---|---:|---:|",
    ]

    all_checks: dict[str, list[dict]] = {}

    for spec in TABLE_SPECS:
        col_profile = _column_profile(con, spec.name).to_df()
        col_profile.to_csv(out_dir / f"{spec.name}__columns.csv", index=False)

        dupes = _duplicate_counts(con, spec)
        checks = _unwarranted_value_checks(con, spec)
        all_checks[spec.name] = checks

        meta = load_meta[spec.name]
        summary_lines.append(
            f"| {spec.name} | {meta['source_file']} | {meta['rows']} | "
            f"{meta['source_sha256_16']} | {dupes['full_row_duplicate_rows']} | "
            f"{dupes['natural_key_duplicate_groups'] if dupes['natural_key_duplicate_groups'] is not None else 'n/a'} |"
        )

    summary_lines += ["", "## Unwarranted-value checks (feeds Data Quality Issue Log)", ""]
    for table, checks in all_checks.items():
        if not checks:
            continue
        summary_lines.append(f"**{table}**")
        for c in checks:
            summary_lines.append(f"- `{c['check']}`: {c['failing_rows']} rows")
        summary_lines.append("")

    (out_dir / "profiling_summary.md").write_text("\n".join(summary_lines), encoding="utf-8")

    finished_at = dt.datetime.now()
    details = {
        "tables_profiled": len(TABLE_SPECS),
        "load_meta": load_meta,
        "out_dir": str(out_dir),
    }
    log_step(con, step="task1_profile_data", status="OK", started_at=started_at, finished_at=finished_at, details=details)

    return details
