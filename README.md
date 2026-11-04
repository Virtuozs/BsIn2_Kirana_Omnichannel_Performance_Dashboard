# KIRANA Omnichannel Performance Intelligence

UAS Business Intelligence Systems (individual take-home project) — a DuckDB + Metabase
pipeline supporting one decision: **realokasi anggaran promo & perbaikan kinerja toko
untuk H2 2026** for KIRANA Home & Living, a fictional omnichannel retailer (18 stores +
Website/Mobile App/Marketplace).

Full task breakdown and status: see [`TASK_LIST.md`](../TASK_LIST.md) (one level up).

## Pipeline

```
Data/raw_data/*.csv, *.xlsx          (never edited manually)
        │
        ▼  sql/01_load_raw.sql        raw.*        (typed-as-text load)
        ▼  sql/02_staging.sql         staging.*    (typed, deduped, normalized — every
        │                                           transform tagged with its ISSUE-xx)
        ▼  sql/03_star_schema.sql     model.*      (star schema: fact_sales, fact_returns,
        │                                           fact_target_net_sales + dims)
        ▼  sql/04_quality_tests.sql   model.dq_test_results   (8 tests, blocking/warning)
        ▼  sql/05_reconciliation.sql  model.reconciliation    (raw → fact row/value diff)
        ▼  sql/06_kpi_views.sql       model.vw_*   (10-KPI metric layer)
        │
        ▼
   db/kirana.duckdb  ──read-only──▶  Metabase (dashboard, 5 tabs)
```

Orchestrated by `scripts/02_build_model.py` (layers 01–05) and `scripts/03_build_kpis.py`
(layer 06), both reusing `scripts/lib/paths.py` and `scripts/lib/run_log.py` from Task 1
(`scripts/01_profile_data.py`) for a consistent run-log/accountability pattern
(`_meta.run_log`). All layers are idempotent — safe to rerun any number of times.

## Setup

```bash
uv sync                      # installs duckdb==1.5.6, pandas, openpyxl into .venv
```

## Rebuilding the database from raw

```bash
uv run python scripts/01_profile_data.py   # profiling evidence -> evidence/task1_profiling/
uv run python scripts/02_build_model.py    # raw -> staging -> star schema -> quality tests -> reconciliation
uv run python scripts/03_build_kpis.py     # KPI views (model.vw_*)
```

Or run the SQL layers directly against the DuckDB CLI (same engine version as the
Metabase driver, pinned to `1.5.6`):

```bash
duckdb db/kirana.duckdb < sql/01_load_raw.sql
duckdb db/kirana.duckdb < sql/02_staging.sql
duckdb db/kirana.duckdb < sql/03_star_schema.sql
duckdb db/kirana.duckdb < sql/04_quality_tests.sql
duckdb db/kirana.duckdb < sql/05_reconciliation.sql
duckdb db/kirana.duckdb < sql/06_kpi_views.sql
```

## Metabase & draw.io

```bash
docker compose up -d                 # starts Metabase (localhost:3000) + draw.io (localhost:8081)
./tools/metabase/load_driver.sh       # loads the DuckDB community driver into Metabase's /plugins volume
```

- Metabase image: `ghcr.io/motherduckdb/metabase-duckdb:latest` (Ubuntu/glibc). The
  official Alpine `metabase/metabase` image JVM-segfaults on the DuckDB driver (musl/glibc
  allocator mismatch) — see the Task 4 note in `TASK_LIST.md`.
- Add `db/kirana.duckdb` (mounted read-only at `/data/db/kirana.duckdb`) as a database in
  Metabase Admin → Databases once the star schema exists.
- Public sharing is disabled site-wide; no dashboard is exposed via public link.

## Project structure

| Path | Contents |
|---|---|
| `Data/raw_data/` | Raw source files (untouched) + data dictionary `README.md` |
| `sql/` | Layered SQL pipeline (`01_load_raw` → `06_kpi_views`) |
| `scripts/` | Python orchestrators + shared `lib/` (paths, run log, profiling) |
| `db/kirana.duckdb` | Built DuckDB database (raw/staging/model/\_meta schemas) |
| `artifacts/task1`–`task6` | Decision statement, grain statement, KPI dictionary, wireframes, insight notes, governance docs |
| `evidence/task1_profiling`–`task6_governance` | Graded evidence per task (CSVs, screenshots, exported PDFs) |
| `tools/metabase/` | DuckDB driver jar + loader script for the Metabase container |
| `docker-compose.yml` | Metabase + draw.io services |

## Key decisions

- **Grain & star schema**: see `artifacts/task2/grain_statement.md` and
  `artifacts/task2/star_schema.drawio`.
- **KPI dictionary** (10 metrics, formulas, grain, owner, thresholds):
  `artifacts/task3/kpi_dictionary.md`.
- **Data quality issue log** (14 issues found across Tasks 1–4, each quantified in rows
  and Rupiah): `artifacts/task1/data_quality_issue_log.csv`.
- **Governance**: PII (name/phone/email/birth date) is dropped at the staging layer and
  never reaches `model.*` or the dashboard; access design and Metabase permission graph in
  `artifacts/task6/evaluation_and_governance.html`.
