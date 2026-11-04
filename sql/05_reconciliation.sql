-- ============================================================
-- Layer 5: RECONCILIATION
-- Row count and value from raw -> clean fact, with every adjustment
-- attributed to a specific logged issue. Written to model.reconciliation
-- (overwritten each run -- this is a point-in-time report, not a log;
-- compare with _meta.run_log / model.dq_test_results for run history).
-- Depends on: 03_star_schema.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS model;

CREATE OR REPLACE TABLE model.reconciliation AS
WITH pos_raw AS (
    SELECT count(*) AS rows, sum(TRY_CAST(qty AS DOUBLE) * TRY_CAST(unit_price AS DOUBLE)
                                 - TRY_CAST(discount_amount AS DOUBLE)) AS value
    FROM raw.sales_pos_transactions
),
pos_fact AS (
    SELECT count(*) AS rows, sum(net_amount) AS value
    FROM model.fact_sales WHERE source_system = 'POS'
),
online_raw AS (
    SELECT count(*) AS rows,
           sum(COALESCE(TRY_CAST(item_price AS DOUBLE),
                        TRY_CAST(replace(replace(item_price,'Rp',''),'.','') AS DOUBLE))
               * TRY_CAST(qty AS DOUBLE)
               - TRY_CAST(voucher_amount AS DOUBLE)) AS value
    FROM raw.sales_online_orders
),
online_fact AS (
    SELECT count(*) AS rows, sum(net_amount) AS value
    FROM model.fact_sales WHERE source_system = 'ONLINE'
),
returns_raw AS (
    SELECT count(*) AS rows, sum(TRY_CAST(refund_amount AS DOUBLE)) AS value FROM raw.returns
),
returns_fact AS (
    SELECT count(*) AS rows, sum(refund_amount) AS value FROM model.fact_returns
)
SELECT * FROM (
    VALUES
    ('sales_pos_transactions -> fact_sales (POS)',
        (SELECT rows FROM pos_raw), (SELECT rows FROM pos_fact),
        (SELECT rows FROM pos_raw) - (SELECT rows FROM pos_fact),
        round((SELECT value FROM pos_raw), 2), round((SELECT value FROM pos_fact), 2),
        'ISSUE-01 (-1495 exact dupes); value unchanged by normalization fixes (ISSUE-03/09/10 don''t change amounts)'),

    ('sales_online_orders -> fact_sales (ONLINE)',
        (SELECT rows FROM online_raw), (SELECT rows FROM online_fact),
        (SELECT rows FROM online_raw) - (SELECT rows FROM online_fact),
        round((SELECT value FROM online_raw), 2), round((SELECT value FROM online_fact), 2),
        'ISSUE-05 (-232 exact dupes); raw value computed with the same ISSUE-11 Rp-string parsing used in staging, so both sides are comparable'),

    ('returns -> fact_returns',
        (SELECT rows FROM returns_raw), (SELECT rows FROM returns_fact),
        (SELECT rows FROM returns_raw) - (SELECT rows FROM returns_fact),
        round((SELECT value FROM returns_raw), 2), round((SELECT value FROM returns_fact), 2),
        'No rows dropped -- fact_returns keeps all 18090 rows, including the 1 unmatched ISSUE-07 orphan (flagged via matched_to_fact_sales=false, not excluded)')
) AS t(layer, raw_rows, fact_rows, rows_dropped, raw_value, fact_value, note);

SELECT * FROM model.reconciliation;
