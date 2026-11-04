"""Task 3: KPI & Kamus Metrik. Standalone entrypoint.

Builds the KPI semantic layer (sql/06_kpi_views.sql): VIEWs over
model.fact_sales / model.fact_returns / model.fact_target_net_sales that
bake in every KPI's inclusion/exclusion rule once, so every Metabase
question built on them uses an identical definition. See
artifacts/task3/kpi_dictionary.md for the KPI-by-KPI business
definitions this view layer implements.

Same accountability pattern as scripts/01_profile_data.py (Task 1) and
scripts/02_build_model.py (Task 2): one _meta.run_log row per run.

Usage:
    uv run python scripts/03_build_kpis.py

Idempotent: every statement in sql/06_kpi_views.sql is CREATE OR REPLACE
VIEW -- no data is materialized, rerunning just redefines the same views.
"""

import sys
import datetime as dt
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import duckdb

from scripts.lib.paths import DB_PATH, PROJECT_ROOT
from scripts.lib.run_log import log_step

SQL_PATH = PROJECT_ROOT / "sql" / "06_kpi_views.sql"


def main() -> None:
    con = duckdb.connect(str(DB_PATH))
    try:
        started_at = dt.datetime.now()
        try:
            con.execute(SQL_PATH.read_text(encoding="utf-8"))
            status = "OK"
            details = {"sql_file": str(SQL_PATH.relative_to(PROJECT_ROOT))}
        except Exception as exc:
            status = "FAILED"
            details = {"sql_file": str(SQL_PATH.relative_to(PROJECT_ROOT)), "error": str(exc)}
            log_step(con, step="task3_06_kpi_views.sql", status=status,
                      started_at=started_at, finished_at=dt.datetime.now(), details=details)
            raise
        finished_at = dt.datetime.now()
        log_step(con, step="task3_06_kpi_views.sql", status=status,
                  started_at=started_at, finished_at=finished_at, details=details)
        print(f"  [{status}] 06_kpi_views.sql ({(finished_at - started_at).total_seconds():.1f}s)")

        print("\nKPI views created:")
        print(con.execute("""
            SELECT view_name FROM duckdb_views()
            WHERE schema_name = 'model' AND view_name LIKE 'vw_%'
            ORDER BY view_name
        """).fetchdf().to_string(index=False))

        print("\nSanity check -- Net Sales & Gross Margin % by channel (all-time):")
        print(con.execute("""
            SELECT channel_code,
                   sum(net_amount) AS net_sales,
                   round(100.0 * sum(gross_margin_amount) / sum(net_amount), 1) AS gross_margin_pct
            FROM model.vw_sales_metrics
            GROUP BY 1 ORDER BY 1
        """).fetchdf().to_string(index=False))

        print("\nSanity check -- Achievement % by channel (2025 full year):")
        print(con.execute("""
            SELECT channel, sum(target_net_sales) AS target, sum(actual_net_sales) AS actual,
                   round(100.0 * sum(actual_net_sales) / sum(target_net_sales), 1) AS achv_pct
            FROM model.vw_achievement_monthly
            WHERE target_year = 2025
            GROUP BY 1 ORDER BY 1
        """).fetchdf().to_string(index=False))
    finally:
        con.close()


if __name__ == "__main__":
    main()
