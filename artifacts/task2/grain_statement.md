# Task 2: Grain Statement, Star Schema & SCD Decisions

## 1. `model.fact_sales` Grain Statement

> **One row = one resolved sale line item**, from either the Store (POS) or
> Online (Website / Mobile App / Marketplace) channel, after exact
> re-export duplicates are removed (ISSUE-01, ISSUE-05).

**Row identity does NOT use the source system's own line key.** Task 1
(ISSUE-02) found that `(trx_id, line_no)` in `sales_pos_transactions.csv`
is **not unique** even after dropping exact duplicates. 102 groups (204
rows) share a `(trx_id, line_no)` pair across genuinely different sale
lines (different `cashier_id`/`sku`/`qty`). Trusting that pair as a
primary key would silently drop real revenue.

Instead, `fact_sales.sales_line_sk` is a surrogate key generated in
staging:

```sql
'POS-' || row_number() OVER (ORDER BY trx_id, line_no, sku)   -- POS rows
'ONL-' || row_number() OVER (ORDER BY order_no, line_no)      -- online rows (key confirmed unique after dedup)
```

Tested in `sql/04_quality_tests.sql` (`TEST-01`, blocking): 0 duplicate
`sales_line_sk` values.

## 2. SCD Decisions

### (a) Product cost: `product_cost_history.csv`

**Decision: use as a point-in-time (SCD2-style) bridge, joined at fact
build time, not folded into `dim_product`.**

`dim_product` carries only the *current* descriptive attributes
(name/category/brand/current price), using SCD Type 1, since those rarely
change and don't affect historical calculations.

`unit_cost`, however, directly determines COGS and gross margin for a
*historical* sale, and the source data already gives us a clean SCD2
timeline (`valid_from`/`valid_to` per SKU, verified in Task 1: every SKU
has exactly one currently-valid row, 0 overlapping ranges). So
`fact_sales.unit_cost_at_sale` is resolved per row via:

```sql
LEFT JOIN staging.stg_product_cost_history ch
  ON ch.sku = <sale>.sku
 AND <sale date> BETWEEN ch.valid_from AND ch.valid_to
```

**Impact if this were done wrong** (e.g. always using
`dim_product.current_unit_cost`): every sale before the most recent cost
change would compute margin using a cost that didn't apply at the time,
silently misstating historical gross margin and contribution margin,
exactly the KPI that drives the promo-reallocation decision.
`TEST-03`/reconciliation confirm `unit_cost_at_sale` is 0% null across
all 472,319 fact rows.

### (b) Store region: `store_region_history.csv`

**Decision: synthesize full SCD2 coverage in `model.bridge_store_region_history`, joined at fact build time, not read directly from `dim_store`.**

`store_region_history.csv` only lists stores that have **actually
changed region**. In this dataset, exactly 1 store (`BGR-01`, moved from
"Jawa Barat" to "Jabodetabek" on 2025-07-01). The other 17 stores have
*no* history rows at all. `bridge_store_region_history` is built as:

```sql
SELECT store_code, region, valid_from, valid_to FROM staging.stg_store_region_history   -- the 1 store that moved
UNION ALL
SELECT store_code, region_current, '2024-01-01', '9999-12-31' FROM staging.stg_stores   -- synthesized "always valid" row for the other 17
```

`fact_sales.region_at_sale` then resolves per row via
`store_code + sale_date BETWEEN valid_from AND valid_to`, never from
`dim_store.region` directly.

**Impact if this were done wrong** (e.g. using `dim_store`'s current
region for all history): every BGR-01 sale before 2025-07-01 would be
counted against the **Jabodetabek** target instead of **Jawa Barat**,
which is exactly the achievement-vs-target number Task 2's business
question #1 and the toko/region decision (Task 1's decision statement)
depend on. `TEST-05` (blocking) verifies the bridge has no overlapping
date ranges per store, so this join can never fan out.

Two additional rows were added to the same bridge/dim_store pattern
during Task 2, not because they're SCD per se, but because they needed
the same "don't silently drop to NULL" treatment:

- **ISSUE-09**: `store_code` case variants (`jkt-01` vs `JKT-01`) for all
  17 real stores, fixed by `UPPER(TRIM(store_code))` normalization.
- **ISSUE-10**: `store_code = 'TRN-99'` (320 rows, Rp 76,366,200) doesn't
  match any real store under any casing, and its `trx_id` format itself
  differs from real stores. Rather than drop real revenue or guess which
  store it belongs to, it's kept as an explicit, labeled
  `is_registered = false` row ("Toko Tidak Terdaftar") so it's visible
  and filterable in the dashboard, satisfying the brief's "penanda data
  tidak lengkap" requirement.

## 3. Star Schema

```
                         model.dim_date
                               |
  model.dim_product --- model.fact_sales --- model.dim_store
                               |        \
                     model.dim_customer  model.bridge_store_region_history
                               |
                         model.dim_promo
                               |
                        model.dim_channel

  model.fact_returns  --(original_trx_id)--> model.fact_sales.source_doc_id  [not enforced FK; 1 orphan, ISSUE-07]
  model.fact_target_net_sales  -- (channel, region, year, month) -- independent grain, compared to fact_sales in metric views (Task 3)
```

| Table | Type | Grain |
|---|---|---|
| `dim_date` | Dimension | 1 row per calendar date, 2024-01-01..2026-12-31 |
| `dim_product` | Dimension (SCD1) | 1 row per SKU (post ISSUE-06 dedup) |
| `dim_store` | Dimension (SCD1) | 1 row per store_code (18 real + 1 unregistered, ISSUE-10) |
| `dim_channel` | Dimension | 1 row per channel (4) |
| `dim_customer` | Dimension (PII-minimized) | 1 row per customer_id + 1 `NON_MEMBER` row |
| `dim_promo` | Dimension | 1 row per promo_code (post ISSUE-06-style dedup; + `NO_PROMO` + unregistered `B2B-CORP`, ISSUE-08) |
| `bridge_store_region_history` | SCD2 bridge | 1 row per store region-validity period |
| `fact_sales` | Fact | 1 resolved sale line item (see grain statement above) |
| `fact_returns` | Fact | 1 returned item line (= `returns.csv` grain) |
| `fact_target_net_sales` | Fact | 1 (channel, region, year, month) target figure, unpivoted from the wide source sheets |

See `artifacts/task2/star_schema.drawio` for the visual diagram.

## 4. PII Minimization (Task 2 requirement, formalized in Task 6)

`model.dim_customer` excludes `full_name`, `phone`, `email`, `birth_date`
entirely, dropped in `staging.stg_customers`, never loaded into the
model layer, so they cannot reach Metabase even by accident.
