-- ============================================================
-- Layer 1: LOAD RAW
-- Reads raw/*.csv and the targets .xlsx directly from Data/raw_data/
-- into schema `raw`, with no transformation beyond typed-as-text load.
-- Idempotent: CREATE OR REPLACE, safe to rerun any number of times.
-- Run from the project root (BsIn_UAS/), e.g.:
--   duckdb db/kirana.duckdb < sql/01_load_raw.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS raw;
INSTALL excel;
LOAD excel;

CREATE OR REPLACE TABLE raw.sales_pos_transactions AS
SELECT * FROM read_csv('Data/raw_data/sales_pos_transactions.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.sales_online_orders AS
SELECT * FROM read_csv('Data/raw_data/sales_online_orders.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.products AS
SELECT * FROM read_csv('Data/raw_data/products.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.product_cost_history AS
SELECT * FROM read_csv('Data/raw_data/product_cost_history.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.stores AS
SELECT * FROM read_csv('Data/raw_data/stores.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.store_region_history AS
SELECT * FROM read_csv('Data/raw_data/store_region_history.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.store_events AS
SELECT * FROM read_csv('Data/raw_data/store_events.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.customers AS
SELECT * FROM read_csv('Data/raw_data/customers.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.returns AS
SELECT * FROM read_csv('Data/raw_data/returns.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.promotions AS
SELECT * FROM read_csv('Data/raw_data/promotions.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.channel_fee_rates AS
SELECT * FROM read_csv('Data/raw_data/channel_fee_rates.csv',
    header = true, all_varchar = true, sample_size = -1);

CREATE OR REPLACE TABLE raw.pos_sync_log AS
SELECT * FROM read_csv('Data/raw_data/pos_sync_log.csv',
    header = true, all_varchar = true, sample_size = -1);

-- Targets workbook: title + blank row before the header, 3 sheets.
CREATE OR REPLACE TABLE raw.target_net_sales_2025 AS
SELECT * FROM read_xlsx('Data/raw_data/sales_targets_2025_2026.xlsx',
    sheet = 'Target Net Sales 2025', range = 'A3:N200',
    header = true, all_varchar = true, stop_at_empty = true);

CREATE OR REPLACE TABLE raw.target_net_sales_h1_2026 AS
SELECT * FROM read_xlsx('Data/raw_data/sales_targets_2025_2026.xlsx',
    sheet = 'Target Net Sales H1 2026', range = 'A3:H200',
    header = true, all_varchar = true, stop_at_empty = true);

CREATE OR REPLACE TABLE raw.target_gm AS
SELECT * FROM read_xlsx('Data/raw_data/sales_targets_2025_2026.xlsx',
    sheet = 'Target GM', range = 'A1:C200',
    header = true, all_varchar = true, stop_at_empty = true);
