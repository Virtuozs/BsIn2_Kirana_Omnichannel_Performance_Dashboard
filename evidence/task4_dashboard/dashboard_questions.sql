-- Task 4 -- SQL behind every dashboard question (KIRANA Home & Living -- Omnichannel Performance)
-- Dashboard: http://localhost:3000/dashboard/2 (private Metabase instance, not publicly shared)

-- [Executive Overview] KPI - Net Sales  (card id 40)
SELECT sum(net_amount) AS net_sales FROM model.vw_sales_metrics WHERE 1=1 [[AND sale_date >= {{date_from}}]] [[AND sale_date <= {{date_to}}]] [[AND {{channel}}]] [[AND {{region}}]] [[AND {{category}}]];

-- [Executive Overview] KPI - Gross Margin %  (card id 41)
SELECT round(100.0*sum(gross_margin_amount)/sum(net_amount),1) AS gross_margin_pct FROM model.vw_sales_metrics WHERE 1=1 [[AND sale_date >= {{date_from}}]] [[AND sale_date <= {{date_to}}]] [[AND {{channel}}]] [[AND {{region}}]] [[AND {{category}}]];

-- [Executive Overview] KPI - Contribution Margin %  (card id 42)
SELECT round(100.0*sum(contribution_margin_amount)/sum(net_amount),1) AS contribution_margin_pct FROM model.vw_sales_metrics WHERE 1=1 [[AND sale_date >= {{date_from}}]] [[AND sale_date <= {{date_to}}]] [[AND {{channel}}]] [[AND {{region}}]] [[AND {{category}}]];

-- [Executive Overview] KPI - Jumlah Transaksi  (card id 43)
SELECT count(DISTINCT source_doc_id) AS transactions FROM model.vw_sales_metrics WHERE 1=1 [[AND sale_date >= {{date_from}}]] [[AND sale_date <= {{date_to}}]] [[AND {{channel}}]] [[AND {{region}}]] [[AND {{category}}]];

-- [Executive Overview] Net Sales Aktual vs Target per Bulan per Channel  (card id 44)
SELECT make_date(target_year, month_num, 1) AS bulan, channel, actual_net_sales, target_net_sales FROM model.vw_achievement_monthly WHERE 1=1 [[AND {{channel2}}]] ORDER BY 1;

-- [Executive Overview] Achievement % per Channel (Tahun Terbaru)  (card id 45)
SELECT channel, round(100.0*sum(actual_net_sales)/sum(target_net_sales),1) AS achievement_pct FROM model.vw_achievement_monthly WHERE target_year = (SELECT max(target_year) FROM model.vw_achievement_monthly) GROUP BY 1 ORDER BY 1;

-- [Executive Overview] Penanda Data Tidak Lengkap (Store Tidak Terdaftar + Sync Bermasalah)  (card id 46)
SELECT store_code, count(*) AS baris, sum(net_amount) AS net_sales, 'Toko tidak terdaftar (ISSUE-10)' AS catatan FROM model.vw_sales_metrics WHERE store_code = 'TRN-99' GROUP BY 1 UNION ALL SELECT store_code, count(*) AS baris, NULL AS net_sales, 'Sync POS bermasalah: ' || sync_status AS catatan FROM staging.stg_pos_sync_log WHERE sync_status != 'SUCCESS' GROUP BY 1, sync_status;

-- [Executive Overview] Indikator Kesegaran Data (Data Terakhir per Toko)  (card id 47)
SELECT store_code, max(business_date) AS tanggal_data_terakhir, max(synced_at) AS waktu_sync_terakhir, CASE WHEN max(business_date) < current_date - INTERVAL 1 DAY THEN 'STALE' ELSE 'OK' END AS status FROM staging.stg_pos_sync_log GROUP BY 1 ORDER BY 1;

-- [Channel, Region & Store Performance] Net Sales & Achievement % per Region  (card id 48)
SELECT region, sum(actual_net_sales) AS net_sales, round(100.0*sum(actual_net_sales)/sum(target_net_sales),1) AS achievement_pct FROM model.vw_achievement_monthly WHERE target_year = (SELECT max(target_year) FROM model.vw_achievement_monthly) GROUP BY 1 ORDER BY 2 DESC;

-- [Channel, Region & Store Performance] Performa per Toko  (card id 49)
SELECT s.store_code, d.store_name, d.region, d.is_registered, count(DISTINCT s.source_doc_id) AS transaksi, sum(s.net_amount) AS net_sales, round(100.0*sum(s.gross_margin_amount)/sum(s.net_amount),1) AS gross_margin_pct FROM model.vw_sales_metrics s LEFT JOIN model.dim_store d ON d.store_code = s.store_code WHERE s.store_code IS NOT NULL [[AND s.sale_date >= {{date_from}}]] [[AND s.sale_date <= {{date_to}}]] [[AND {{region3}}]] GROUP BY 1,2,3,4 ORDER BY net_sales DESC;

-- [Margin & Promotion Effectiveness] Gross Margin % vs Contribution Margin % per Channel  (card id 50)
SELECT channel_code, round(100.0*sum(gross_margin_amount)/sum(net_amount),1) AS gross_margin_pct, round(100.0*sum(contribution_margin_amount)/sum(net_amount),1) AS contribution_margin_pct FROM model.vw_sales_metrics WHERE 1=1 [[AND sale_date >= {{date_from}}]] [[AND sale_date <= {{date_to}}]] GROUP BY 1 ORDER BY 1;

-- [Margin & Promotion Effectiveness] AOV Promo vs Non-Promo per Kategori (Promo Lift)  (card id 51)
SELECT category, is_promo, round(sum(net_amount)/count(DISTINCT source_doc_id)) AS aov FROM model.vw_sales_metrics WHERE category IS NOT NULL [[AND sale_date >= {{date_from}}]] [[AND sale_date <= {{date_to}}]] GROUP BY 1,2 ORDER BY 1,2;

-- [Margin & Promotion Effectiveness] Detail Promo  (card id 52)
SELECT p.promo_code, p.promo_name, p.discount_pct, p.budget_idr, p.is_unregistered, sum(s.net_amount) AS net_sales_terkait, count(DISTINCT s.source_doc_id) AS transaksi FROM model.dim_promo p LEFT JOIN model.vw_sales_metrics s ON s.promo_code = p.promo_code WHERE p.promo_code != 'NO_PROMO' GROUP BY 1,2,3,4,5 ORDER BY net_sales_terkait DESC;

-- [Returns & Customers] Return Rate per Channel  (card id 53)
WITH sales AS (SELECT channel_code, sum(net_amount) AS net_sales FROM model.vw_sales_metrics WHERE 1=1 [[AND sale_date >= {{date_from}}]] [[AND sale_date <= {{date_to}}]] GROUP BY 1), returns AS (SELECT channel, sum(refund_amount) AS refund FROM model.vw_returns_metrics GROUP BY 1) SELECT s.channel_code, round(100.0*r.refund/s.net_sales,2) AS return_rate_pct FROM sales s JOIN returns r ON r.channel = s.channel_code ORDER BY 1;

-- [Returns & Customers] Alasan Retur Terbanyak  (card id 54)
SELECT return_reason, count(*) AS jumlah, sum(refund_amount) AS nilai_refund FROM model.vw_returns_metrics GROUP BY 1 ORDER BY 2 DESC;

-- [Returns & Customers] Active Members per Bulan  (card id 55)
SELECT sale_month, count(DISTINCT customer_id) AS active_members FROM model.vw_customer_order_monthly GROUP BY 1 ORDER BY 1;

-- [Returns & Customers] Repeat Rate (Lifetime)  (card id 56)
SELECT round(100.0*sum(CASE WHEN is_repeat_customer THEN 1 ELSE 0 END)/count(*),1) AS repeat_rate_pct FROM model.vw_customer_lifetime;
