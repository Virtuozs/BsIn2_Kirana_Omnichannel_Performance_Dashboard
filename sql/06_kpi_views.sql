-- ============================================================
-- Layer 6: KPI SEMANTIC LAYER (model schema, VIEWs not TABLEs)
--
-- Every KPI in artifacts/task3/kpi_dictionary.md is backed by exactly
-- one of the views below. Metabase questions/dashboards must query
-- these views (not model.fact_sales / model.fact_returns directly) so
-- every chart uses the same inclusion/exclusion rules:
--   - CANCELLED online orders excluded from all sales/margin KPIs
--     (order_status='CANCELLED'; POS has no such status -> always kept)
--   - discount_amount / voucher_amount already netted into net_amount
--     (see sql/03_star_schema.sql fact_sales)
--   - channel fee is time-based (staging.stg_channel_fee_rates has a
--     mid-2025 Marketplace rate change) -> resolved by date, not a flat %
--
-- Depends on: 03_star_schema.sql (model.fact_sales/fact_returns/dim_*),
--             02_staging.sql (stg_channel_fee_rates)
-- Views only -- CREATE OR REPLACE VIEW is naturally idempotent, no data
-- is materialized here, so there is nothing to append-log beyond the
-- _meta.run_log step row scripts/03_build_kpis.py already writes.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS model;

-- ---------------------------------------------------------------
-- model.vw_sales_metrics
-- GRAIN: one row = one model.fact_sales line (same grain as the fact).
-- Base view for KPI-01 Net Sales, KPI-03 Gross Margin %,
-- KPI-04 Contribution Margin %, KPI-06 AOV, KPI-07 Transaction Count,
-- KPI-10 Promo Lift.
--
-- Inclusion/exclusion baked in here (not left to each question):
--   - DROPS order_status='CANCELLED' (online only; 12,733 rows / 209,394
--     online lines = 6.08% of online volume -- see kpi_dictionary.md
--     KPI-01 for the reconciliation query)
--   - KEEPS all POS rows (order_status is structurally NULL for POS --
--     the source system has no cancellation concept, confirmed in
--     Task 1 profiling)
--   - channel_fee_amount resolved by (channel_code, sale_date) against
--     the time-sliced staging.stg_channel_fee_rates, so the Apr-2025
--     Marketplace rate change (9.0% -> 11.5%) is applied correctly to
--     historical sales instead of using today's rate everywhere
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW model.vw_sales_metrics AS
SELECT
    fs.sales_line_sk,
    fs.source_system,
    fs.source_doc_id,
    fs.sale_date,
    fs.sale_datetime,
    date_trunc('month', fs.sale_date)::DATE       AS sale_month,
    fs.channel_code,
    dc.channel_group,
    fs.region_at_sale,
    fs.store_code,
    fs.sku,
    dp.category,
    dp.subcategory,
    fs.customer_id,
    fs.promo_code,
    (fs.promo_code != 'NO_PROMO')                 AS is_promo,
    fs.qty,
    fs.unit_price,
    fs.discount_amount,
    fs.gross_amount,
    fs.net_amount,
    fs.cogs_amount,
    (fs.net_amount - fs.cogs_amount)              AS gross_margin_amount,
    cf.fee_pct_of_net_sales,
    round(fs.net_amount * coalesce(cf.fee_pct_of_net_sales, 0) / 100.0, 2) AS channel_fee_amount,
    (fs.net_amount - fs.cogs_amount
        - fs.net_amount * coalesce(cf.fee_pct_of_net_sales, 0) / 100.0)   AS contribution_margin_amount
FROM model.fact_sales fs
JOIN model.dim_channel dc ON dc.channel_code = fs.channel_code
LEFT JOIN model.dim_product dp ON dp.sku = fs.sku
LEFT JOIN staging.stg_channel_fee_rates cf
    ON cf.channel = fs.channel_code
   AND fs.sale_date BETWEEN cf.valid_from AND cf.valid_to
WHERE fs.order_status IS NULL OR fs.order_status != 'CANCELLED';

-- ---------------------------------------------------------------
-- model.vw_returns_metrics
-- GRAIN: one row = one model.fact_returns line.
-- Base view for KPI-05 Return Rate.
-- No inclusion/exclusion filter is applied (every logged return is a
-- real return event, including the ISSUE-07 orphan row -- it is kept
-- visible via matched_to_fact_sales rather than silently dropped).
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW model.vw_returns_metrics AS
SELECT
    r.return_id,
    r.return_date,
    date_trunc('month', r.return_date)::DATE      AS return_month,
    r.channel,
    dc.channel_group,
    r.store_code,
    r.sku,
    dp.category,
    r.return_qty,
    r.refund_amount,
    r.return_reason,
    r.matched_to_fact_sales
FROM model.fact_returns r
JOIN model.dim_channel dc ON dc.channel_code = r.channel
LEFT JOIN model.dim_product dp ON dp.sku = r.sku;

-- ---------------------------------------------------------------
-- model.vw_achievement_monthly
-- GRAIN: one row = one (channel, region, year, month).
-- Base view for KPI-02 Achievement vs Target %.
--
-- ISSUE-13 (found while building this view): fact_target_net_sales'
-- region labels (from the wide target sheets) use different spelling/
-- casing/abbreviation than fact_sales.region_at_sale -- e.g. 'JABODETABEK'
-- vs 'Jabodetabek', 'Jabar' vs 'Jawa Barat', 'Jateng-DIY' vs
-- 'Jateng & DIY', 'Jatim' vs 'Jawa Timur', 'Bali Nusra' vs
-- 'Bali & Nusa Tenggara', 'Sumatra' vs 'Sumatera'. A naive string join
-- would silently return 0 for every Store/region achievement row.
-- Normalized here via explicit mapping (both sides upper-cased/trimmed
-- first so future casing drift doesn't reopen this). `region`='Nasional'
-- is the literal whole-company target (Marketplace/Mobile App/Website
-- are never split by region in the source) -- actual is summed across
-- ALL regions for that channel/month in that case.
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW model.vw_achievement_monthly AS
WITH target_region_map AS (
    SELECT *, CASE upper(trim(region))
        WHEN 'JABODETABEK'  THEN 'Jabodetabek'
        WHEN 'JABAR'        THEN 'Jawa Barat'
        WHEN 'JATENG-DIY'   THEN 'Jateng & DIY'
        WHEN 'JATIM'        THEN 'Jawa Timur'
        WHEN 'BALI NUSRA'   THEN 'Bali & Nusa Tenggara'
        WHEN 'SUMATRA'      THEN 'Sumatera'
        WHEN 'NASIONAL'     THEN 'Nasional'
        ELSE region
    END AS region_norm
    FROM model.fact_target_net_sales
),
actual AS (
    SELECT channel_code AS channel, region_at_sale AS region,
           extract(year FROM sale_date)  AS target_year,
           extract(month FROM sale_date) AS month_num,
           sum(net_amount) AS actual_net_sales
    FROM model.vw_sales_metrics
    GROUP BY 1, 2, 3, 4
),
actual_national AS (
    SELECT channel_code AS channel, 'Nasional' AS region,
           extract(year FROM sale_date)  AS target_year,
           extract(month FROM sale_date) AS month_num,
           sum(net_amount) AS actual_net_sales
    FROM model.vw_sales_metrics
    GROUP BY 1, 2, 3, 4
)
SELECT
    t.channel, t.region AS region_raw, t.region_norm AS region,
    t.target_year, t.month_num,
    t.target_net_sales,
    coalesce(a.actual_net_sales, an.actual_net_sales, 0) AS actual_net_sales,
    round(100.0 * coalesce(a.actual_net_sales, an.actual_net_sales, 0)
          / t.target_net_sales, 1) AS achievement_pct
FROM target_region_map t
LEFT JOIN actual a
    ON a.channel = t.channel AND a.region = t.region_norm
   AND a.target_year = t.target_year AND a.month_num = t.month_num
LEFT JOIN actual_national an
    ON t.region_norm = 'Nasional'
   AND an.channel = t.channel
   AND an.target_year = t.target_year AND an.month_num = t.month_num;

-- ---------------------------------------------------------------
-- model.vw_customer_order_monthly
-- GRAIN: one row = one (customer_id, sale_month) with >=1 completed
-- order that month. Excludes 'NON_MEMBER' (guest sales have no durable
-- customer identity to track activity/repeat against).
-- Base view for KPI-08 Active Members and KPI-09 Repeat Rate.
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW model.vw_customer_order_monthly AS
SELECT
    customer_id,
    sale_month,
    count(DISTINCT source_doc_id) AS orders_in_month,
    sum(net_amount)               AS net_sales_in_month
FROM model.vw_sales_metrics
WHERE customer_id != 'NON_MEMBER'
GROUP BY 1, 2;

-- ---------------------------------------------------------------
-- model.vw_customer_lifetime
-- GRAIN: one row = one customer_id (member only), across the full data
-- window. Base view for KPI-09 Repeat Rate denominator/numerator.
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW model.vw_customer_lifetime AS
SELECT
    customer_id,
    count(DISTINCT source_doc_id)        AS lifetime_orders,
    min(sale_date)                        AS first_order_date,
    max(sale_date)                        AS last_order_date,
    (count(DISTINCT source_doc_id) > 1)  AS is_repeat_customer
FROM model.vw_sales_metrics
WHERE customer_id != 'NON_MEMBER'
GROUP BY 1;
