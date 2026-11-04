-- ============================================================
-- Layer 4: DATA QUALITY TESTS
-- 8 tests (minimum required: 6), each classified blocking/warning,
-- results written to model.dq_test_results (append-only per run, like
-- _meta.run_log in scripts/lib/run_log.py -- same accountability
-- pattern as Task 1).
--
-- TEST-04 is DESIGNED TO FAIL: fact_returns.original_trx_id must match
-- a transaction in fact_sales. It fails for exactly 1 row -- the known,
-- already-investigated ISSUE-07 orphan return. Classified WARNING
-- (not blocking) because it's a single explained exception, not a
-- systemic defect; a blocking test would stop the whole pipeline over
-- one legitimate return whose source transaction never synced from POS.
--
-- Depends on: 03_star_schema.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS model;

CREATE TABLE IF NOT EXISTS model.dq_test_results (
    run_ts        TIMESTAMP,
    test_id       VARCHAR,
    test_name     VARCHAR,
    classification VARCHAR,     -- 'blocking' | 'warning'
    rows_failed   BIGINT,
    passed        BOOLEAN,
    description   VARCHAR
);

INSERT INTO model.dq_test_results
WITH checks(test_id, test_name, classification, rows_failed, description) AS (
    VALUES
    ('TEST-01', 'fact_sales.sales_line_sk is unique', 'blocking',
        (SELECT count(*) - count(DISTINCT sales_line_sk) FROM model.fact_sales),
        'Surrogate line key must be unique or every downstream aggregate is wrong'),

    ('TEST-02', 'dim_product.sku is unique', 'blocking',
        (SELECT count(*) - count(DISTINCT sku) FROM model.dim_product),
        'Duplicate SKU in dim_product breaks every fact_sales join (ISSUE-06)'),

    ('TEST-03', 'fact_sales.qty and unit_price are not null', 'blocking',
        (SELECT count(*) FROM model.fact_sales WHERE qty IS NULL OR unit_price IS NULL),
        'A sale line with no quantity or price cannot be summed into net sales'),

    ('TEST-04', 'fact_returns.original_trx_id resolves to a fact_sales row', 'warning',
        (SELECT count(*) FROM model.fact_returns WHERE matched_to_fact_sales = false),
        'Intentionally failing test (1 row, ISSUE-07): return RT0012517 references a trx_id never present in POS -- likely a pos_sync_log gap, not a return to discard'),

    ('TEST-05', 'bridge_store_region_history has no overlapping date ranges per store', 'blocking',
        (SELECT count(*) FROM model.bridge_store_region_history a
         JOIN model.bridge_store_region_history b
           ON a.store_code = b.store_code AND a.valid_from < b.valid_from
          AND a.valid_to >= b.valid_from),
        'Overlapping validity ranges would make the fact_sales region-at-sale join return duplicate rows'),

    ('TEST-06', 'dim_customer.member_tier is a known value', 'warning',
        (SELECT count(*) FROM model.dim_customer
         WHERE member_tier NOT IN ('Gold','Silver','Platinum','Non-Member')),
        'Unexpected tier value would silently fall out of tier-based promo-effectiveness slicing'),

    ('TEST-07', 'fact_sales.region_at_sale is never null', 'blocking',
        (SELECT count(*) FROM model.fact_sales WHERE region_at_sale IS NULL),
        'A null region silently disappears from every region-level rollup (would regress ISSUE-09/ISSUE-10 fix)'),

    ('TEST-08', 'fact_sales.channel_code is one of the 4 known channels', 'warning',
        (SELECT count(*) FROM model.fact_sales WHERE channel_code NOT IN (SELECT channel_code FROM model.dim_channel)),
        'An unrecognized channel code would not join dim_channel and drop out of channel-sliced KPIs')
)
SELECT now(), test_id, test_name, classification, rows_failed, (rows_failed = 0) AS passed, description
FROM checks;

-- Show this run's results (most recent run_ts)
SELECT test_id, test_name, classification, rows_failed, passed
FROM model.dq_test_results
WHERE run_ts = (SELECT max(run_ts) FROM model.dq_test_results)
ORDER BY test_id;
