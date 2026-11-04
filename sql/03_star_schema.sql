-- ============================================================
-- Layer 3: STAR SCHEMA (model)
-- Dimensions use stable natural keys (sku, store_code, channel_code,
-- customer_id, promo_code, date) rather than meaningless surrogate
-- integers -- see artifacts/task2/grain_statement.md for the reasoning.
-- Depends on: 02_staging.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS model;

-- Data coverage window (01 Jan 2024 - 30 Jun 2026 per Data/README.md),
-- extended through end of 2026 so H2 2026 targets/promos can be added
-- later without rebuilding dim_date.
CREATE OR REPLACE TABLE model.dim_date AS
SELECT
    CAST(strftime(d, '%Y%m%d') AS INTEGER) AS date_sk,
    d                                       AS date,
    extract(year FROM d)                    AS year,
    extract(quarter FROM d)                 AS quarter,
    extract(month FROM d)                   AS month,
    strftime(d, '%B')                       AS month_name,
    strftime(d, '%Y-%m')                    AS year_month,
    extract(day FROM d)                     AS day,
    extract(dow FROM d)                     AS day_of_week,          -- 0=Sunday
    extract(dow FROM d) IN (0, 6)           AS is_weekend
FROM range(DATE '2024-01-01', DATE '2027-01-01', INTERVAL 1 DAY) t(d);

-- ---------------------------------------------------------------
-- dim_product (SCD1: current descriptive attributes only)
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE model.dim_product AS
SELECT sku, product_name, category, subcategory, brand,
       current_list_price, current_unit_cost, launch_date
FROM staging.stg_products;

-- ---------------------------------------------------------------
-- dim_store (SCD1: current attributes; current region only -- for
-- point-in-time region at the moment of a given sale, fact_sales joins
-- bridge_store_region_history instead)
-- ---------------------------------------------------------------
-- ISSUE-10: 'TRN-99' appears in sales_pos_transactions.csv under a
-- trx_id format that doesn't match any real store ('TRN-99-MMDD-...' vs
-- 'JKT-01-YYMMDD-...') and is absent from stores.csv entirely. Added
-- here as an explicitly-flagged row (is_registered=false) so it
-- resolves to a visible label in fact_sales rather than a silent NULL
-- that would just vanish from region/store roll-ups.
CREATE OR REPLACE TABLE model.dim_store AS
SELECT store_code, store_name, city, province, region_current AS region,
       store_type, open_date, selling_area_sqm, status, true AS is_registered
FROM staging.stg_stores
UNION ALL
SELECT 'TRN-99', 'Tidak terdaftar di stores.csv (lihat ISSUE-10)', NULL, NULL, NULL,
       NULL, NULL, NULL, 'Unregistered', false;

-- ---------------------------------------------------------------
-- bridge_store_region_history (SCD2, point-in-time region resolution)
--   SCD DECISION: store_region_history.csv only lists stores that have
--   actually changed region (2 rows, covering 1 store). For the other
--   17 stores we synthesize a single "always valid" row from
--   dim_store's current region, spanning the full data window, so every
--   (store_code, date) pair resolves unambiguously. See
--   artifacts/task2/grain_statement.md for why this matters: target
--   achievement must be measured against the region a store belonged
--   to AT THE TIME, not its region today.
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE model.bridge_store_region_history AS
SELECT store_code, region, valid_from, valid_to
FROM staging.stg_store_region_history
UNION ALL
SELECT s.store_code, s.region_current AS region,
       DATE '2024-01-01' AS valid_from, DATE '9999-12-31' AS valid_to
FROM staging.stg_stores s
WHERE s.store_code NOT IN (SELECT DISTINCT store_code FROM staging.stg_store_region_history)
UNION ALL
-- ISSUE-10: give the unregistered 'TRN-99' code an explicit, visible
-- region label instead of leaving it NULL (silently dropped by GROUP BY)
SELECT 'TRN-99', 'Toko Tidak Terdaftar', DATE '2024-01-01', DATE '9999-12-31';

-- ---------------------------------------------------------------
-- dim_channel
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE model.dim_channel AS
SELECT * FROM (VALUES
    ('Store',       'Offline', false),
    ('Website',     'Online',  true),
    ('Mobile App',  'Online',  true),
    ('Marketplace', 'Online',  true)
) AS t(channel_code, channel_group, is_online);

-- ---------------------------------------------------------------
-- dim_customer -- PII already excluded in staging.stg_customers.
-- A synthetic 'NON_MEMBER' row covers guest sales (member_id/customer_id
-- is NULL), so fact_sales.customer_id is never an unresolved FK.
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE model.dim_customer AS
SELECT customer_id, gender, city, join_date, join_channel, member_tier
FROM staging.stg_customers
UNION ALL
SELECT 'NON_MEMBER', NULL, NULL, NULL, NULL, 'Non-Member';

-- ---------------------------------------------------------------
-- dim_promo -- synthetic rows for: no promo used, and promo codes used
-- in POS but absent from promotions.csv (ISSUE-08: 'B2B-CORP').
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE model.dim_promo AS
SELECT promo_code, promo_name, channel_scope, category_scope,
       discount_pct, start_date, end_date, budget_idr, member_only,
       false AS is_unregistered
FROM staging.stg_promotions
UNION ALL
SELECT 'NO_PROMO', 'Tidak memakai promo', NULL, NULL, NULL, NULL, NULL, NULL, NULL, false
UNION ALL
SELECT DISTINCT p.promo_code, 'Tidak terdaftar di promotions.csv (lihat ISSUE-08)',
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, true
FROM staging.stg_sales_pos p
WHERE p.promo_code IS NOT NULL
  AND p.promo_code NOT IN (SELECT promo_code FROM staging.stg_promotions);

-- ---------------------------------------------------------------
-- fact_sales
-- GRAIN: one row = one resolved sale line item (POS or Online), after
-- exact-duplicate removal (ISSUE-01/05). Source line identity uses a
-- surrogate sales_line_sk, NOT the source (trx_id, line_no) /
-- (order_no, line_no) pair -- see ISSUE-02: that pair is not reliably
-- unique in the POS source even after dedup.
-- Full statement: artifacts/task2/grain_statement.md
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE model.fact_sales AS
WITH pos AS (
    SELECT
        'POS-' || p.pos_line_sk                        AS sales_line_sk,
        'POS'                                           AS source_system,
        p.trx_id                                        AS source_doc_id,
        p.trx_date                                      AS sale_date,
        p.trx_datetime                                   AS sale_datetime,
        'Store'                                          AS channel_code,
        p.store_code                                     AS store_code,
        CAST(NULL AS VARCHAR)                             AS ship_city,
        CAST(NULL AS VARCHAR)                             AS ship_province,
        p.sku                                             AS sku,
        coalesce(p.member_id, 'NON_MEMBER')               AS customer_id,
        p.qty                                             AS qty,
        p.unit_price                                      AS unit_price,
        p.discount_amount                                 AS discount_amount,
        coalesce(p.promo_code, 'NO_PROMO')                AS promo_code,
        p.payment_type                                    AS payment_method,
        CAST(NULL AS VARCHAR)                              AS order_status,
        br.region                                          AS region_at_sale,
        ch.unit_cost                                       AS unit_cost_at_sale
    FROM staging.stg_sales_pos p
    LEFT JOIN model.bridge_store_region_history br
        ON br.store_code = p.store_code
       AND p.trx_date BETWEEN br.valid_from AND br.valid_to
    LEFT JOIN staging.stg_product_cost_history ch
        ON ch.sku = p.sku
       AND p.trx_date BETWEEN ch.valid_from AND ch.valid_to
),
online AS (
    SELECT
        'ONL-' || o.online_line_sk                      AS sales_line_sk,
        'ONLINE'                                         AS source_system,
        o.order_no                                       AS source_doc_id,
        o.order_date                                     AS sale_date,
        o.order_datetime                                 AS sale_datetime,
        o.sales_channel                                  AS channel_code,
        CAST(NULL AS VARCHAR)                             AS store_code,
        o.ship_city                                       AS ship_city,
        o.ship_province                                   AS ship_province,
        o.sku                                             AS sku,
        coalesce(o.customer_id, 'NON_MEMBER')             AS customer_id,
        o.qty                                             AS qty,
        o.item_price                                      AS unit_price,
        o.voucher_amount                                  AS discount_amount,
        coalesce(o.voucher_code, 'NO_PROMO')              AS promo_code,
        o.payment_method                                  AS payment_method,
        o.order_status                                    AS order_status,
        -- Province -> official region, per Data/README.md. Jabodetabek
        -- satellite cities (Bogor/Depok/Bekasi/Tangerang) ship under
        -- province "Jawa Barat"/"Banten" but belong to Jabodetabek --
        -- verified against dim_store's own province/region pairs.
        CASE
            WHEN o.ship_province IN ('DKI Jakarta', 'Banten') THEN 'Jabodetabek'
            WHEN o.ship_province = 'Jawa Barat'
                 AND (o.ship_city ILIKE 'Bogor%' OR o.ship_city ILIKE 'Depok%'
                      OR o.ship_city ILIKE 'Bekasi%' OR o.ship_city ILIKE 'Tangerang%')
                THEN 'Jabodetabek'
            WHEN o.ship_province = 'Jawa Barat' THEN 'Jawa Barat'
            WHEN o.ship_province IN ('Jawa Tengah', 'DI Yogyakarta') THEN 'Jateng & DIY'
            WHEN o.ship_province = 'Jawa Timur' THEN 'Jawa Timur'
            WHEN o.ship_province = 'Bali' THEN 'Bali & Nusa Tenggara'
            WHEN o.ship_province IN ('Sumatera Utara', 'Sumatera Selatan', 'Riau', 'Lampung')
                THEN 'Sumatera'
            ELSE 'Lainnya'
        END AS region_at_sale,
        ch.unit_cost AS unit_cost_at_sale
    FROM staging.stg_sales_online o
    LEFT JOIN staging.stg_product_cost_history ch
        ON ch.sku = o.sku
       AND o.order_date BETWEEN ch.valid_from AND ch.valid_to
)
SELECT *,
       qty * unit_price                                  AS gross_amount,
       qty * unit_price - discount_amount                AS net_amount,
       qty * unit_cost_at_sale                            AS cogs_amount
FROM pos
UNION ALL
SELECT *,
       qty * unit_price                                  AS gross_amount,
       qty * unit_price - discount_amount                AS net_amount,
       qty * unit_cost_at_sale                            AS cogs_amount
FROM online;

-- ---------------------------------------------------------------
-- fact_returns
-- GRAIN: one row = one returned item line (returns.csv is already at
-- this grain; return_id is unique per Task 1 profiling).
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE model.fact_returns AS
SELECT
    return_id, return_date, original_trx_id, channel, store_code, sku,
    return_qty, refund_amount, return_reason,
    EXISTS (
        SELECT 1 FROM model.fact_sales fs
        WHERE fs.source_doc_id = r.original_trx_id
    ) AS matched_to_fact_sales                            -- ISSUE-07: false for 1 row
FROM staging.stg_returns r;

-- ---------------------------------------------------------------
-- fact_target_net_sales
-- GRAIN: one row = one (channel, region_or_national, target_year, month)
-- target figure. Unpivoted from the wide monthly-column source sheets.
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE model.fact_target_net_sales AS
SELECT
    channel, region, target_year,
    CAST(right(month_col, -1) AS INTEGER) AS month_num,   -- 'm7' -> 7
    target_net_sales
FROM (
    SELECT channel, region, target_year, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12
    FROM staging.stg_target_net_sales_wide
)
UNPIVOT (target_net_sales FOR month_col IN (m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,m11,m12))
WHERE target_net_sales IS NOT NULL;   -- H1-2026 sheet has NULL m7..m12 (no H2 target yet)
