# Task 4: Interactive Dashboard - Build Notes & Evidence Index

Dashboard: **KIRANA Home & Living -- Omnichannel Performance**, Metabase
dashboard id 2, collection "KIRANA Dashboard".

## Infra change required

The official `metabase/metabase:v0.63.17` image (Alpine/musl) cannot run
the MotherDuck DuckDB JDBC driver. It loads but **segfaults the JVM**
the first time a query touches the native lib (`malloc_init_hard` crash
under Alpine's `gcompat` glibc shim; confirmed via container logs).
Switched `docker-compose.yml`'s `metabase` service to
`ghcr.io/motherduckdb/metabase-duckdb:latest` (Ubuntu/glibc, driver
`0.63.17-duckdb1.5.6.0`, an exact match to our pinned DuckDB 1.5.6). That
image runs as uid 999, so `/metabase-data` is a **named Docker volume**
with ownership fixed via a one-off `chown` (same WSL2 bind-mount
work-around already used for `/plugins` in Task 2's setup, generalized
here since this image needs it for its whole app-db, not just plugins).

Metabase's `KIRANA (model)` database connection points at
`/data/db/kirana.duckdb` (read-only): **only `model.*` and the KPI
views built in Task 3** are meant to back dashboard questions;
`raw.*`/`staging.*` remain technically browsable (same DuckDB file) but
nothing on the dashboard queries them except `staging.stg_pos_sync_log`
for the freshness indicator, which carries no PII.

## Structure

4 tabs, 21 dashcards total (4 text/section headers + 17 questions), one
shared filter bar (`Periode`, `Channel`, `Region`, `Kategori`, scoped
per-tab to only the filters that tab's cards actually use):

| Tab | Cards |
|---|---|
| Executive Overview | 4 KPI scalars (Net Sales, Gross Margin %, Contribution Margin %, Jumlah Transaksi), Net Sales Aktual vs Target trend line, Achievement % per Channel (color-coded table), Penanda Data Tidak Lengkap, Indikator Kesegaran Data |
| Channel, Region & Store Performance | Net Sales & Achievement % per Region (color-coded table), Performa per Toko (drill table, `is_registered` flag) |
| Margin & Promotion Effectiveness | Gross Margin % vs Contribution Margin % per Channel, AOV Promo vs Non-Promo per Kategori (Promo Lift), Detail Promo |
| Returns & Customers | Return Rate per Channel, Alasan Retur Terbanyak, Active Members per Bulan, Repeat Rate |

Every question is a **native SQL question against `model.vw_*`** (not
the query builder) so the exact SQL is inspectable and matches
`artifacts/task3/kpi_dictionary.md`'s documented formulas exactly. See
`evidence/task4_dashboard/dashboard_questions.sql` for all 17.

## Required features: where each lives

- **Filters** (periode/channel/region/kategori): dashboard-level
  parameters, wired via Field Filter template tags (`{{channel}}` etc.
  bound to real columns) or plain date variables (`{{date_from}}`,
  `{{date_to}}`), using Metabase's `[[AND ...]]` optional-filter syntax
  so an unset filter doesn't error the query.
- **Click behavior / drill-through**: "Achievement % per Channel"
  (Tab 1) cross-filters the tab's own `Channel` parameter, which feeds
  the 4 KPI scalars + trend line on the same tab. "Net Sales &
  Achievement % per Region" (Tab 2) cross-filters `Region`, which feeds
  "Performa per Toko" on the same tab. Table cards additionally get
  Metabase's native per-cell drill ("see these records").
- **Status colors**: `table.column_formatting` conditional ranges
  (red<90, yellow 90-99, green>=100) on `achievement_pct` in both
  Tab 1's and Tab 2's tables; `gross_margin_pct` in "Performa per Toko"
  colored similarly (red<35%, green>=50%).
- **Data-freshness indicator**: "Indikator Kesegaran Data" table, from
  `staging.stg_pos_sync_log`, flags `STALE` when a store's last synced
  `business_date` is more than 1 day before `current_date`.
- **Incomplete-data markers**: "Penanda Data Tidak Lengkap" table unions
  the unregistered `TRN-99` store code (ISSUE-10) with every
  `stg_pos_sync_log` row where `sync_status != 'SUCCESS'`.
- **PII**: zero dashboard question references `raw.customers` or any of
  `full_name`/`phone`/`email`/`birth_date`, verified by reading every
  query in `dashboard_questions.sql`; customer-related cards use only
  `customer_id` (an opaque id, not PII) and aggregates.
- **No public sharing**: `enable-public-sharing` set to `false`
  site-wide via `PUT /api/setting/enable-public-sharing`; confirmed
  `dashboard.public_uuid` is `null`.

## A real data issue found and fixed via this dashboard (ISSUE-14)

Building the "AOV Promo vs Non-Promo per Kategori" chart surfaced 9
category bars instead of the expected 7, because `products.csv.category` had
case/accent variants (`Home Decor`/`Home Décor`, `Kitchen & Dining`/
`kitchen & dining`, 14 SKUs, 12,280 affected `fact_sales` rows, Rp
2,316,514,800). Fixed in `staging.stg_products` (`sql/02_staging.sql`),
logged as ISSUE-14 in `artifacts/task1/data_quality_issue_log.csv` +
`issue_checks.sql`, full pipeline (`scripts/02_build_model.py` +
`scripts/03_build_kpis.py`) re-run and re-verified (all 8 quality tests
still pass identically; reconciliation unchanged) before the dashboard
was re-screenshotted to confirm the fix.

## Evidence files

- `artifacts/task4/dashboard_wireframe.drawio`: annotated wireframe
  (goal/users/decisions supported), built before the dashboard
- `evidence/task4_dashboard/dashboard_export.pdf`: all 4 tabs, full
  page screenshots taken live from the running dashboard
- `evidence/task4_dashboard/screenshots/*.png`: the same, individually
- `evidence/task4_dashboard/dashboard_questions.sql`: SQL for all 17
  dashboard questions, tagged by tab
