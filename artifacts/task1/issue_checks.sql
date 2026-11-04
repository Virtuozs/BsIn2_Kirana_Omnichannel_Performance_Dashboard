-- Task 1: Data Quality Issue Log - supporting queries
--
-- Reproduces every number in data_quality_issue_log.csv directly against
-- raw.* (loaded by scripts/01_profile_data.py / scripts/lib/profiling.py).
-- Run with:  duckdb db/kirana.duckdb < artifacts/task1/issue_checks.sql
-- (run from the BsIn_UAS/ project root)


-- ISSUE-01: exact full-row duplicates in sales_pos_transactions
-- Expect: rows_to_drop=1495, rupiah_value_dropped=360895500
WITH exact_dupes AS (
    SELECT *,
        row_number() OVER (
            PARTITION BY trx_id, line_no, trx_datetime, store_code, cashier_id,
                         member_id, sku, qty, unit_price, discount_amount,
                         promo_code, payment_type
            ORDER BY trx_id
        ) AS rn
    FROM raw.sales_pos_transactions
)
SELECT
    count(*) FILTER (WHERE rn > 1) AS rows_to_drop,
    sum(TRY_CAST(qty AS DOUBLE) * TRY_CAST(unit_price AS DOUBLE)
        - TRY_CAST(discount_amount AS DOUBLE)) FILTER (WHERE rn > 1) AS rupiah_value_dropped
FROM exact_dupes;


-- ISSUE-02: (trx_id, line_no) still collides after ISSUE-01 dedup
-- Expect: collision_groups=102, rows_involved=204
WITH exact_dupes AS (
    SELECT *,
        row_number() OVER (
            PARTITION BY trx_id, line_no, trx_datetime, store_code, cashier_id,
                         member_id, sku, qty, unit_price, discount_amount,
                         promo_code, payment_type
            ORDER BY trx_id
        ) AS rn
    FROM raw.sales_pos_transactions
),
deduped AS (SELECT * FROM exact_dupes WHERE rn = 1),
still_colliding AS (
    SELECT trx_id, line_no, count(*) AS n
    FROM deduped
    GROUP BY trx_id, line_no
    HAVING count(*) > 1
)
SELECT count(*) AS collision_groups, sum(n) AS rows_involved FROM still_colliding;

-- ISSUE-03: inconsistent SKU formatting in sales_pos_transactions
-- Expect: rows_malformed_sku=2650, rupiah_value_affected=645744200
SELECT
    count(*) FILTER (WHERE sku != upper(trim(sku))) AS rows_malformed_sku,
    sum(TRY_CAST(qty AS DOUBLE) * TRY_CAST(unit_price AS DOUBLE))
        FILTER (WHERE sku != upper(trim(sku))) AS rupiah_value_affected
FROM raw.sales_pos_transactions;

-- Confirms normalization is safe (no orphaned SKUs after UPPER(TRIM(...))):
-- Expect: unmatched=0
SELECT count(*) AS unmatched
FROM raw.sales_pos_transactions t
WHERE upper(trim(t.sku)) NOT IN (SELECT upper(trim(sku)) FROM raw.products);


-- ISSUE-04: order_date format (DD/MM/YYYY HH:MM) false-flagged by
-- generic date casting
-- Expect: unparseable_generic=209626 (100%), unparseable_with_format=0
SELECT count(*) AS unparseable_generic
FROM raw.sales_online_orders
WHERE COALESCE(TRY_CAST(order_date AS TIMESTAMP), TRY_CAST(order_date AS DATE)) IS NULL
  AND order_date IS NOT NULL AND trim(order_date) != '';

SELECT count(*) AS unparseable_with_format
FROM raw.sales_online_orders
WHERE try_strptime(order_date, '%d/%m/%Y %H:%M') IS NULL
  AND order_date IS NOT NULL AND trim(order_date) != '';


-- ISSUE-05: exact full-row duplicates in sales_online_orders
-- Expect: rows_to_drop=232, rupiah_value_dropped=48915600,
--         collision_groups_after_dedup=0 (key is clean once deduped)
-- NOTE: value uses the ISSUE-11-aware price parse (COALESCE of plain
-- TRY_CAST and the "Rp"-stripped TRY_CAST) -- a plain TRY_CAST alone
-- silently drops Rp-formatted rows from the SUM and undercounts (the
-- original pass before ISSUE-11 was found got Rp 41,180,200).
WITH exact_dupes AS (
    SELECT *,
        row_number() OVER (
            PARTITION BY order_no, line_no, order_date, sales_channel, customer_id,
                         ship_city, ship_province, sku, qty, item_price,
                         voucher_code, voucher_amount, payment_method, order_status
            ORDER BY order_no
        ) AS rn
    FROM raw.sales_online_orders
)
SELECT
    count(*) FILTER (WHERE rn > 1) AS rows_to_drop,
    sum(
        TRY_CAST(qty AS DOUBLE) *
        COALESCE(TRY_CAST(item_price AS DOUBLE),
                 TRY_CAST(replace(replace(item_price,'Rp',''),'.','') AS DOUBLE))
        - TRY_CAST(voucher_amount AS DOUBLE)
    ) FILTER (WHERE rn > 1) AS rupiah_value_dropped
FROM exact_dupes;

WITH exact_dupes AS (
    SELECT *,
        row_number() OVER (
            PARTITION BY order_no, line_no, order_date, sales_channel, customer_id,
                         ship_city, ship_province, sku, qty, item_price,
                         voucher_code, voucher_amount, payment_method, order_status
            ORDER BY order_no
        ) AS rn
    FROM raw.sales_online_orders
),
deduped AS (SELECT * FROM exact_dupes WHERE rn = 1),
still_colliding AS (
    SELECT order_no, line_no, count(*) AS n
    FROM deduped
    GROUP BY order_no, line_no
    HAVING count(*) > 1
)
SELECT count(*) AS collision_groups_after_dedup, sum(n) AS rows_involved
FROM still_colliding;


-- ISSUE-06: duplicate SKUs in products.csv ("(old)" legacy name rows)
-- Expect: 6 SKUs, each with 2 rows, identical price/cost between pairs
SELECT sku, count(*) AS n
FROM raw.products
GROUP BY sku
HAVING count(*) > 1;

SELECT sku, product_name, current_list_price, current_unit_cost
FROM raw.products
WHERE sku IN (SELECT sku FROM raw.products GROUP BY sku HAVING count(*) > 1)
ORDER BY sku, product_name;


-- ISSUE-07: orphan return referencing a non-existent original_trx_id
-- Expect: 1 row (Store channel), 0 for online channels
SELECT
    channel,
    count(*) AS total,
    count(*) FILTER (
        WHERE channel = 'Store'
          AND original_trx_id NOT IN (SELECT DISTINCT trx_id FROM raw.sales_pos_transactions)
    ) AS orphan_store,
    count(*) FILTER (
        WHERE channel != 'Store'
          AND original_trx_id NOT IN (SELECT DISTINCT order_no FROM raw.sales_online_orders)
    ) AS orphan_online
FROM raw.returns
GROUP BY channel;

SELECT *
FROM raw.returns
WHERE channel = 'Store'
  AND original_trx_id NOT IN (SELECT DISTINCT trx_id FROM raw.sales_pos_transactions);


-- ============================================================
-- ISSUE-08: POS promo_code values not present in promotions.csv
-- (discovered during Task 2 dim_promo referential check -- online
-- voucher_code is 100% clean against promotions.promo_code, this is
-- POS-specific)
-- Expect: 1 distinct code (B2B-CORP), 14 rows, Rp 499918500
-- Requires staging.stg_sales_pos / staging.stg_promotions (sql/02_staging.sql)
-- ============================================================
SELECT promo_code, count(*) AS n, sum(qty * unit_price - discount_amount) AS rupiah
FROM staging.stg_sales_pos
WHERE promo_code IS NOT NULL
  AND promo_code NOT IN (SELECT promo_code FROM staging.stg_promotions)
GROUP BY promo_code
ORDER BY n DESC;

-- Cross-check: online voucher_code is fully clean against promotions.promo_code
-- Expect: 0
SELECT count(*) AS unmatched_voucher
FROM staging.stg_sales_online o
WHERE o.voucher_code IS NOT NULL
  AND o.voucher_code NOT IN (SELECT promo_code FROM staging.stg_promotions);


-- ============================================================
-- ISSUE-09 / ISSUE-10: store_code case inconsistency + unregistered
-- 'TRN-99' code (discovered during Task 2 fact_sales region resolution
-- -- a region_at_sale NULL-gap investigation surfaced both)
-- Expect: 18 real-store lowercase variants (3555 rows total) + TRN-99
-- (320 rows, Rp 76366200), TRN-99 absent from staging.stg_stores
-- Requires staging.stg_sales_pos BEFORE the store_code UPPER(TRIM())
-- fix -- rerun against raw.sales_pos_transactions directly to reproduce
-- the original finding.
-- ============================================================
SELECT store_code, count(*) AS n
FROM raw.sales_pos_transactions
WHERE upper(trim(store_code)) != store_code
   OR upper(trim(store_code)) NOT IN (SELECT store_code FROM raw.stores)
GROUP BY store_code
ORDER BY store_code;

SELECT count(*) AS n, sum(TRY_CAST(qty AS DOUBLE) * TRY_CAST(unit_price AS DOUBLE)
                           - TRY_CAST(discount_amount AS DOUBLE)) AS rupiah
FROM raw.sales_pos_transactions
WHERE upper(trim(store_code)) = 'TRN-99';

-- Confirms TRN-99 is absent from the store master under any casing:
SELECT * FROM raw.stores WHERE upper(store_code) = 'TRN-99';   -- expect 0 rows


-- ============================================================
-- ISSUE-11: item_price formatted as "Rp99.900" instead of plain number
-- (discovered via Task 2 TEST-03: fact_sales.qty/unit_price not-null check)
-- Expect: 36179 rows in raw; 0 remaining unparseable after the two-step
-- COALESCE(TRY_CAST(...), TRY_CAST(strip 'Rp'/'.' ...)) fix in staging
-- ============================================================
SELECT count(*) AS rp_formatted_rows
FROM raw.sales_online_orders WHERE item_price LIKE 'Rp%';

SELECT count(*) AS still_unparseable_after_fix
FROM raw.sales_online_orders
WHERE item_price LIKE 'Rp%'
  AND TRY_CAST(replace(replace(item_price, 'Rp', ''), '.', '') AS DOUBLE) IS NULL;


-- ============================================================
-- ISSUE-12: sales_channel has 12 spelling/casing variants for 3 channels
-- (discovered via Task 2 TEST-08: fact_sales.channel_code domain check)
-- Expect: 12 distinct raw values; 0 unmapped after CASE normalization
-- ============================================================
SELECT sales_channel, count(*) AS n
FROM raw.sales_online_orders
GROUP BY sales_channel
ORDER BY n DESC;

SELECT count(*) AS unmapped_after_normalization
FROM raw.sales_online_orders
WHERE CASE
    WHEN lower(trim(sales_channel)) IN ('marketplace','mp') THEN 'Marketplace'
    WHEN lower(trim(sales_channel)) IN ('mobile app','app','mobile_app') THEN 'Mobile App'
    WHEN lower(trim(sales_channel)) IN ('website','web','web store') THEN 'Website'
  END IS NULL;


-- ============================================================
-- ISSUE-13: Store target region labels don't match fact_sales
-- region_at_sale labels (discovered while building Task 3's
-- model.vw_achievement_monthly -- a naive join returns 0 actual for
-- every Store region)
-- Expect: 108 Store target rows (6 regions x 18 months), total target
-- Rp 40,413,000,000; 0 rows match region_at_sale without normalization
-- Requires model.fact_target_net_sales / model.fact_sales (sql/03_star_schema.sql)
-- ============================================================
SELECT DISTINCT region FROM model.fact_target_net_sales WHERE channel = 'Store'
EXCEPT
SELECT DISTINCT region_at_sale FROM model.fact_sales WHERE channel_code = 'Store';
-- Expect: all 6 Store target region labels returned (none match directly)

SELECT count(*) AS n_rows, sum(target_net_sales) AS total_target
FROM model.fact_target_net_sales WHERE channel = 'Store';

-- Confirms a naive (unnormalized) join matches 0 rows:
SELECT count(*) AS naive_join_matches
FROM model.fact_target_net_sales t
JOIN (SELECT DISTINCT region_at_sale AS region FROM model.fact_sales WHERE channel_code = 'Store') s
  ON s.region = t.region
WHERE t.channel = 'Store';


-- ============================================================
-- ISSUE-14: products.csv.category has case/accent variants of the same
-- category (discovered visually while reviewing the Task 4 dashboard's
-- "Promo Lift per Kategori" chart -- it showed 9 categories instead of 7)
-- Expect: 'Home Decor' 92 SKU vs 'Home Décor' 9 SKU; 'Kitchen & Dining'
-- 105 SKU vs 'kitchen & dining' 5 SKU; 14 SKU / 12,280 fact_sales rows /
-- Rp 2,316,514,800 affected; 0 variants remaining after normalization
-- ============================================================
SELECT category, count(*) AS skus FROM raw.products GROUP BY 1 ORDER BY 1;

SELECT count(*) AS affected_lines, sum(net_amount) AS affected_value
FROM model.vw_sales_metrics
WHERE category IN ('Home Décor', 'kitchen & dining');

-- Confirms 0 variants remain after the staging fix:
SELECT category, count(*) AS skus FROM staging.stg_products GROUP BY 1 ORDER BY 1;
