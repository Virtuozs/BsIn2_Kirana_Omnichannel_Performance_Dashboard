-- ============================================================
-- Layer 2: STAGING
-- Typed, deduplicated, normalized. Every transformation here is a direct
-- fix for an issue logged in artifacts/task1/data_quality_issue_log.csv
-- (referenced inline as -- ISSUE-xx). Idempotent (CREATE OR REPLACE).
-- Depends on: 01_load_raw.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS staging;

-- ---------------------------------------------------------------
-- stg_sales_pos
--   ISSUE-01: drop exact full-row re-export duplicates (DISTINCT)
--   ISSUE-02: (trx_id, line_no) is not a reliable row key even after
--             dedup -- assign a surrogate pos_line_sk instead of trusting
--             source line_no as unique
--   ISSUE-03: normalize sku -> UPPER(TRIM(sku))
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_sales_pos AS
SELECT
    row_number() OVER (ORDER BY trx_id, line_no, sku) AS pos_line_sk,
    trx_id,
    TRY_CAST(line_no AS INTEGER)           AS line_no_src,
    TRY_CAST(trx_datetime AS TIMESTAMP)    AS trx_datetime,
    TRY_CAST(trx_datetime AS DATE)         AS trx_date,
    upper(trim(store_code))                AS store_code,          -- ISSUE-09
    trim(cashier_id)                       AS cashier_id,
    NULLIF(trim(member_id), '')            AS member_id,
    upper(trim(sku))                       AS sku,                 -- ISSUE-03
    TRY_CAST(qty AS INTEGER)               AS qty,
    TRY_CAST(unit_price AS DOUBLE)         AS unit_price,
    TRY_CAST(discount_amount AS DOUBLE)    AS discount_amount,
    NULLIF(trim(promo_code), '')           AS promo_code,
    trim(payment_type)                     AS payment_type
FROM (
    SELECT DISTINCT *                                               -- ISSUE-01
    FROM raw.sales_pos_transactions
);

-- ---------------------------------------------------------------
-- stg_sales_online
--   ISSUE-04: order_date is DD/MM/YYYY HH:MM, not ISO -- explicit strptime
--   ISSUE-05: drop exact full-row re-export duplicates (DISTINCT);
--             (order_no, line_no) is confirmed unique after dedup
--   ISSUE-11: item_price sometimes formatted as "Rp99.900" (Rp prefix +
--             "." thousands separator) instead of a plain number
--   ISSUE-12: sales_channel has 12 spelling/casing/abbreviation variants
--             for the same 3 channels (e.g. "MP", "APP", "Web Store")
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_sales_online AS
SELECT
    row_number() OVER (ORDER BY order_no, line_no) AS online_line_sk,
    order_no,
    TRY_CAST(line_no AS INTEGER)                      AS line_no_src,
    try_strptime(order_date, '%d/%m/%Y %H:%M')        AS order_datetime,   -- ISSUE-04
    CAST(try_strptime(order_date, '%d/%m/%Y %H:%M') AS DATE) AS order_date,
    CASE lower(trim(sales_channel))                                        -- ISSUE-12
        WHEN 'marketplace' THEN 'Marketplace'
        WHEN 'mp'          THEN 'Marketplace'
        WHEN 'mobile app'  THEN 'Mobile App'
        WHEN 'app'         THEN 'Mobile App'
        WHEN 'mobile_app'  THEN 'Mobile App'
        WHEN 'website'     THEN 'Website'
        WHEN 'web'         THEN 'Website'
        WHEN 'web store'   THEN 'Website'
        ELSE trim(sales_channel)
    END                                                AS sales_channel,
    NULLIF(trim(customer_id), '')                     AS customer_id,
    trim(ship_city)                                   AS ship_city,
    trim(ship_province)                               AS ship_province,
    upper(trim(sku))                                  AS sku,
    TRY_CAST(qty AS INTEGER)                          AS qty,
    coalesce(                                                              -- ISSUE-11
        TRY_CAST(item_price AS DOUBLE),
        TRY_CAST(replace(replace(item_price, 'Rp', ''), '.', '') AS DOUBLE)
    )                                                  AS item_price,
    NULLIF(trim(voucher_code), '')                    AS voucher_code,
    TRY_CAST(voucher_amount AS DOUBLE)                AS voucher_amount,
    trim(payment_method)                              AS payment_method,
    trim(order_status)                                AS order_status
FROM (
    SELECT DISTINCT *                                                -- ISSUE-05
    FROM raw.sales_online_orders
);

-- ---------------------------------------------------------------
-- stg_products
--   ISSUE-06: exclude legacy "(old)"-suffixed duplicate SKU rows
--   ISSUE-14: category has case/accent variants of the same category
--   ("Home Decor" vs "Home Décor", "Kitchen & Dining" vs "kitchen & dining")
--   -- normalized to the majority-count canonical spelling so Metabase
--   category rollups (Task 4 Tab 3) don't silently split one category
--   into two bars.
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_products AS
SELECT
    upper(trim(sku))                        AS sku,
    trim(product_name)                      AS product_name,
    CASE
        WHEN trim(category) IN ('Home Decor', 'Home Décor') THEN 'Home Decor'
        WHEN lower(trim(category)) = 'kitchen & dining' THEN 'Kitchen & Dining'
        ELSE trim(category)
    END                                      AS category,                  -- ISSUE-14
    trim(subcategory)                       AS subcategory,
    trim(brand)                             AS brand,
    TRY_CAST(current_list_price AS DOUBLE)  AS current_list_price,
    TRY_CAST(current_unit_cost AS DOUBLE)   AS current_unit_cost,
    TRY_CAST(launch_date AS DATE)           AS launch_date
FROM raw.products
WHERE product_name NOT ILIKE '%(old)';                               -- ISSUE-06

-- ---------------------------------------------------------------
-- stg_product_cost_history (SCD2 source, already-clean: verified in
-- Task 1 that every SKU has exactly one currently-valid row and no
-- overlapping date ranges)
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_product_cost_history AS
SELECT
    upper(trim(sku))                AS sku,
    TRY_CAST(unit_cost AS DOUBLE)   AS unit_cost,
    TRY_CAST(valid_from AS DATE)    AS valid_from,
    TRY_CAST(valid_to AS DATE)      AS valid_to
FROM raw.product_cost_history;

-- ---------------------------------------------------------------
-- stg_stores
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_stores AS
SELECT
    trim(store_code)                  AS store_code,
    trim(store_name)                  AS store_name,
    trim(city)                        AS city,
    trim(province)                    AS province,
    trim(region)                      AS region_current,
    trim(store_type)                  AS store_type,
    TRY_CAST(open_date AS DATE)       AS open_date,
    TRY_CAST(selling_area_sqm AS DOUBLE) AS selling_area_sqm,
    trim(status)                      AS status
FROM raw.stores;

-- ---------------------------------------------------------------
-- stg_store_region_history (SCD2 source -- only covers stores that have
-- actually changed region; model layer synthesizes full coverage)
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_store_region_history AS
SELECT
    trim(store_code)              AS store_code,
    trim(region)                  AS region,
    TRY_CAST(valid_from AS DATE)  AS valid_from,
    TRY_CAST(valid_to AS DATE)    AS valid_to,
    (trim(is_current) = 'Y')      AS is_current
FROM raw.store_region_history;

-- ---------------------------------------------------------------
-- stg_store_events
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_store_events AS
SELECT
    trim(store_code)              AS store_code,
    trim(event)                   AS event,
    TRY_CAST(start_date AS DATE)  AS start_date,
    TRY_CAST(end_date AS DATE)    AS end_date
FROM raw.store_events;

-- ---------------------------------------------------------------
-- stg_customers -- PII MINIMIZED AT SOURCE: full_name, phone, email,
-- birth_date are dropped here and never reach the model layer or
-- Metabase. (Governance detail documented in Task 6.)
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_customers AS
SELECT
    trim(customer_id)             AS customer_id,
    trim(gender)                  AS gender,
    trim(city)                    AS city,
    TRY_CAST(join_date AS DATE)   AS join_date,
    trim(join_channel)            AS join_channel,
    trim(member_tier)             AS member_tier
FROM raw.customers;

-- ---------------------------------------------------------------
-- stg_returns
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_returns AS
SELECT
    trim(return_id)                   AS return_id,
    TRY_CAST(return_date AS DATE)     AS return_date,
    trim(original_trx_id)             AS original_trx_id,
    trim(channel)                     AS channel,
    NULLIF(trim(store_code), '')      AS store_code,
    upper(trim(sku))                  AS sku,
    TRY_CAST(return_qty AS INTEGER)   AS return_qty,
    TRY_CAST(refund_amount AS DOUBLE) AS refund_amount,
    trim(return_reason)               AS return_reason
FROM raw.returns;

-- ---------------------------------------------------------------
-- stg_promotions
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_promotions AS
SELECT
    trim(promo_code)                AS promo_code,
    trim(promo_name)                AS promo_name,
    trim(channel_scope)             AS channel_scope,
    trim(category_scope)            AS category_scope,
    TRY_CAST(discount_pct AS DOUBLE) AS discount_pct,
    TRY_CAST(start_date AS DATE)    AS start_date,
    TRY_CAST(end_date AS DATE)      AS end_date,
    TRY_CAST(budget_idr AS DOUBLE)  AS budget_idr,
    (lower(trim(member_only)) = 'true') AS member_only
FROM raw.promotions;

-- ---------------------------------------------------------------
-- stg_channel_fee_rates
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_channel_fee_rates AS
SELECT
    trim(channel)                       AS channel,
    TRY_CAST(fee_pct_of_net_sales AS DOUBLE) AS fee_pct_of_net_sales,
    TRY_CAST(valid_from AS DATE)        AS valid_from,
    TRY_CAST(valid_to AS DATE)          AS valid_to,
    trim(note)                          AS note
FROM raw.channel_fee_rates;

-- ---------------------------------------------------------------
-- stg_pos_sync_log
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_pos_sync_log AS
SELECT
    trim(store_code)              AS store_code,
    TRY_CAST(business_date AS DATE) AS business_date,
    trim(sync_status)             AS sync_status,
    TRY_CAST(rows_uploaded AS INTEGER) AS rows_uploaded,
    TRY_CAST(synced_at AS TIMESTAMP)   AS synced_at
FROM raw.pos_sync_log;

-- ---------------------------------------------------------------
-- stg_target_net_sales: UNION the two wide-format sheets, still wide
-- (one column per month) -- unpivoted into a true fact in layer 3.
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_target_net_sales_wide AS
SELECT trim(Channel) AS channel, trim(Region) AS region,
       TRY_CAST("Jan-25" AS DOUBLE) AS m1, TRY_CAST("Feb-25" AS DOUBLE) AS m2,
       TRY_CAST("Mar-25" AS DOUBLE) AS m3, TRY_CAST("Apr-25" AS DOUBLE) AS m4,
       TRY_CAST("May-25" AS DOUBLE) AS m5, TRY_CAST("Jun-25" AS DOUBLE) AS m6,
       TRY_CAST("Jul-25" AS DOUBLE) AS m7, TRY_CAST("Aug-25" AS DOUBLE) AS m8,
       TRY_CAST("Sep-25" AS DOUBLE) AS m9, TRY_CAST("Oct-25" AS DOUBLE) AS m10,
       TRY_CAST("Nov-25" AS DOUBLE) AS m11, TRY_CAST("Dec-25" AS DOUBLE) AS m12,
       2025 AS target_year
FROM raw.target_net_sales_2025
UNION ALL
SELECT trim(Channel) AS channel, trim(Region) AS region,
       TRY_CAST("Jan-26" AS DOUBLE) AS m1, TRY_CAST("Feb-26" AS DOUBLE) AS m2,
       TRY_CAST("Mar-26" AS DOUBLE) AS m3, TRY_CAST("Apr-26" AS DOUBLE) AS m4,
       TRY_CAST("May-26" AS DOUBLE) AS m5, TRY_CAST("Jun-26" AS DOUBLE) AS m6,
       CAST(NULL AS DOUBLE) AS m7, CAST(NULL AS DOUBLE) AS m8,
       CAST(NULL AS DOUBLE) AS m9, CAST(NULL AS DOUBLE) AS m10,
       CAST(NULL AS DOUBLE) AS m11, CAST(NULL AS DOUBLE) AS m12,
       2026 AS target_year
FROM raw.target_net_sales_h1_2026;

-- ---------------------------------------------------------------
-- stg_target_gm
-- ---------------------------------------------------------------
CREATE OR REPLACE TABLE staging.stg_target_gm AS
SELECT
    trim(Channel)                                       AS channel,
    TRY_CAST("Target Gross Margin % (2025)" AS DOUBLE)   AS target_gm_pct_2025,
    TRY_CAST("Target Gross Margin % (H1 2026)" AS DOUBLE) AS target_gm_pct_h1_2026
FROM raw.target_gm;
