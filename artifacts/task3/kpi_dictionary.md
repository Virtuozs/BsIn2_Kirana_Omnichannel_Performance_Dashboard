# Task 3: Kamus Metrik (KPI Dictionary)

10 KPI (melebihi minimum 8). Semua diimplementasikan sebagai **VIEW** di
`model.*` (`sql/06_kpi_views.sql`, dibangun oleh `scripts/03_build_kpis.py`)
supaya setiap pertanyaan/chart Metabase memakai definisi, filter inklusi/
eksklusi, dan resolusi dimensi (region point-in-time, biaya channel
bertingkat waktu, dll) yang **identik**, supaya tidak ada rumus yang ditulis
ulang secara berbeda di tiap dashboard question.

Setiap angka "sanity check" di bawah diverifikasi langsung terhadap
`db/kirana.duckdb` saat dokumen ini ditulis (lihat perintah di tiap
seksi), bukan estimasi.

**Aturan eksklusi global** (berlaku ke semua KPI penjualan, dibakar di
`model.vw_sales_metrics`, lihat komentar di `sql/06_kpi_views.sql`):
- Online `order_status = 'CANCELLED'` **dibuang** (12.733 dari 209.626
  baris online, 6,08%). POS tidak punya status pembatalan (struk yang
  tercetak = transaksi selesai), seluruh baris POS tetap dihitung.
- `discount_amount` (POS) / `voucher_amount` (online) sudah dinetkan ke
  `net_amount` di `fact_sales` (Task 2). Semua KPI net sales memakai
  `net_amount`, bukan `gross_amount`, kecuali disebutkan lain.
- Biaya channel (`channel_fee_amount`) dihitung per baris berdasarkan
  tanggal transaksi terhadap `staging.stg_channel_fee_rates` yang
  bertingkat waktu (komisi Marketplace naik dari 9,0% → 11,5% per April
  2025), bukan tarif datar hari ini diterapkan ke seluruh histori.

---

## KPI-01: Net Sales

| | |
|---|---|
| **Definisi bisnis** | Nilai penjualan bersih setelah diskon/voucher, tidak termasuk order yang dibatalkan |
| **Grain** | Fleksibel, view di grain baris (`sales_line_sk`), diagregasi sesuai potongan dashboard (per hari/channel/region/kategori/toko) |
| **Rumus SQL** | `SUM(net_amount)` dari `model.vw_sales_metrics` |
| **Inklusi/eksklusi** | Buang `order_status='CANCELLED'` (online); diskon/voucher sudah ternetkan |
| **Metric owner** | Direktur Komersial (lintas channel); Manajer Channel (per channel) |
| **Target/ambang** | Dibandingkan ke `model.fact_target_net_sales` bulanan (lihat KPI-02) |

Sanity check (all-time, per channel):
```sql
SELECT channel_code, sum(net_amount) FROM model.vw_sales_metrics GROUP BY 1;
-- Marketplace 21.72B | Mobile App 15.25B | Store 62.32B | Website 7.59B
```

---

## KPI-02: Achievement vs Target %

| | |
|---|---|
| **Definisi bisnis** | Realisasi net sales dibanding target bulanan, per channel & region |
| **Grain** | `(channel, region, target_year, month_num)`, `model.vw_achievement_monthly` |
| **Rumus SQL** | `100 * actual_net_sales / target_net_sales` |
| **Inklusi/eksklusi** | Sama seperti KPI-01 untuk `actual`; target channel non-Store (Marketplace/Mobile App/Website) adalah target **nasional** (tidak dipecah per region di sumber), jadi dibandingkan ke total aktual seluruh region |
| **Metric owner** | Direktur Komersial (keputusan realokasi promo & program toko/region bergantung pada KPI ini) |
| **Target/ambang** | 100% = tercapai; <90% = perlu perhatian; >110% = cek apakah target terlalu rendah |

**ISSUE-13 (ditemukan saat membangun view ini):** label region target Store
(`JABODETABEK`, `Jabar`, `Jateng-DIY`, `Jatim`, `Bali Nusra`, `Sumatra`)
beda ejaan dari label `region_at_sale` (`Jabodetabek`, `Jawa Barat`,
`Jateng & DIY`, `Jawa Timur`, `Bali & Nusa Tenggara`, `Sumatera`).
Tanpa normalisasi, join nol baris untuk SEMUA region Store (achievement
0% padahal penjualan ada), dinormalisasi via `CASE` map eksplisit di
`vw_achievement_monthly`, dicatat sebagai ISSUE-13 di
`artifacts/task1/data_quality_issue_log.csv` + `issue_checks.sql`.

Sanity check (2025, per channel):
```sql
SELECT channel, sum(target_net_sales), sum(actual_net_sales)
FROM model.vw_achievement_monthly WHERE target_year=2025 GROUP BY 1;
-- Marketplace 109.0% | Mobile App 119.1% | Store 95.7% | Website 76.0%
```

---

## KPI-03: Gross Margin %

| | |
|---|---|
| **Definisi bisnis** | Margin kotor setelah HPP (sebelum biaya channel) |
| **Grain** | Sama dengan KPI-01 |
| **Rumus SQL** | `100 * SUM(net_amount - cogs_amount) / SUM(net_amount)` dari `model.vw_sales_metrics` (kolom `gross_margin_amount` sudah tersedia) |
| **Inklusi/eksklusi** | Sama seperti KPI-01; `unit_cost_at_sale` di-resolve point-in-time (Task 2 SCD2) jadi margin historis tidak terdistorsi perubahan HPP terbaru |
| **Metric owner** | Direktur Komersial / Finance |
| **Target/ambang** | Dibandingkan ke `staging.stg_target_gm` (target GM% per channel: Store 46%, Website 45%, Mobile App 43%, Marketplace 42%) |

Sanity check:
```sql
SELECT channel_code, round(100*sum(gross_margin_amount)/sum(net_amount),1)
FROM model.vw_sales_metrics GROUP BY 1;
-- Marketplace 42.5% (target 42%) | Mobile App 42.2% (target 43%)
-- Store 45.9% (target 46%) | Website 45.7% (target 45%) -- semua dekat target
```

---

## KPI-04: Contribution Margin % (setelah biaya channel)

| | |
|---|---|
| **Definisi bisnis** | Margin setelah HPP **dan** biaya channel (komisi marketplace, payment gateway, MDR EDC/QRIS), margin riil yang masuk ke perusahaan per channel |
| **Grain** | Sama dengan KPI-01 |
| **Rumus SQL** | `100 * SUM(net_amount - cogs_amount - channel_fee_amount) / SUM(net_amount)`, kolom `contribution_margin_amount` sudah tersedia di `model.vw_sales_metrics` |
| **Inklusi/eksklusi** | `channel_fee_amount` dihitung per baris dari `fee_pct_of_net_sales` yang berlaku pada `sale_date` (lihat `staging.stg_channel_fee_rates`); kenaikan komisi Marketplace April 2025 otomatis terapkan hanya ke baris sesudahnya |
| **Metric owner** | Direktur Komersial (basis utama keputusan realokasi anggaran promo antar-channel) |
| **Target/ambang** | Tidak ada target eksplisit di sumber data; dipakai sebagai pembanding RELATIF antar-channel untuk realokasi, bukan target absolut |

Sanity check. Ini adalah KPI yang paling membedakan Gross Margin vs
Contribution Margin (Marketplace tampak sehat di Gross Margin 42,5% tapi
komisinya 9-11,5% dari net sales, jadi Contribution Margin-nya turun
signifikan lebih dari channel lain):
```sql
SELECT channel_code,
       round(100*sum(gross_margin_amount)/sum(net_amount),1) AS gm_pct,
       round(100*sum(contribution_margin_amount)/sum(net_amount),1) AS cm_pct
FROM model.vw_sales_metrics GROUP BY 1;
```

---

## KPI-05: Return Rate

| | |
|---|---|
| **Definisi bisnis** | Proporsi nilai refund terhadap net sales (value-based, bukan unit-based, karena `refund_amount` lebih langsung menunjukkan dampak finansial) |
| **Grain** | Per channel (bisa diperluas ke kategori via `model.vw_returns_metrics.category`) |
| **Rumus SQL** | `100 * SUM(refund_amount) / SUM(net_amount)`, join `model.vw_returns_metrics.channel = model.vw_sales_metrics.channel_code` |
| **Inklusi/eksklusi** | Retur yang `matched_to_fact_sales=false` (ISSUE-07, 1 baris) **tetap dihitung** dalam total refund, karena baris itu valid sebagai retur, hanya tidak bisa diverifikasi ke transaksi asalnya. Online return TIDAK punya `store_code` (ship dari gudang terpusat, bukan toko fisik) jadi return rate per TOKO hanya tersedia untuk channel Store |
| **Metric owner** | Manajer Operasional / Customer Experience |
| **Target/ambang** | <5% sehat, 5-10% perlu investigasi, >10% perlu tindakan (mis. Website 32,98% jika dihitung naif dgn channel_group salah, lihat catatan di bawah) |

Sanity check (per channel, join langsung pakai `channel`, bukan
`channel_group`, karena percobaan awal salah join lewat `channel_group`
sempat menyamakan refund ketiga channel online, dan dikoreksi sebelum
dirilis ke dokumen ini):
```sql
SELECT s.channel_code, round(100.0*sum(r.refund_amount)/sum(s.net_amount),2)
FROM model.vw_sales_metrics s
JOIN model.vw_returns_metrics r ON r.channel = s.channel_code ...
-- Marketplace 6.39% | Mobile App 5.11% | Store 1.93% | Website 4.41%
```

---

## KPI-06: AOV (Average Order Value)

| | |
|---|---|
| **Definisi bisnis** | Rata-rata nilai bersih per transaksi/order (bukan per baris item) |
| **Grain** | Per channel / periode |
| **Rumus SQL** | `SUM(net_amount) / COUNT(DISTINCT source_doc_id)` dari `model.vw_sales_metrics` |
| **Inklusi/eksklusi** | Sama seperti KPI-01; 1 `source_doc_id` = 1 struk (POS) / 1 order (online), bisa berisi banyak baris sku |
| **Metric owner** | Manajer Channel |
| **Target/ambang** | Dipakai sebagai baseline tren, bukan target absolut tetap |

Sanity check:
```sql
SELECT channel_code, count(DISTINCT source_doc_id), round(sum(net_amount)/count(DISTINCT source_doc_id))
FROM model.vw_sales_metrics GROUP BY 1;
-- Store Rp 432.541 | Website Rp 343.871 | Mobile App Rp 340.892 | Marketplace Rp 333.021
```

---

## KPI-07: Jumlah Transaksi

| | |
|---|---|
| **Definisi bisnis** | Jumlah order/struk unik (bukan jumlah baris item) |
| **Grain** | Per channel/region/periode |
| **Rumus SQL** | `COUNT(DISTINCT source_doc_id)` dari `model.vw_sales_metrics` |
| **Inklusi/eksklusi** | Sama seperti KPI-01 |
| **Metric owner** | Manajer Channel |
| **Target/ambang** | Baseline tren (volume) |

Sanity check: Store 144.089; Marketplace 65.233; Mobile App 44.746;
Website 22.058 transaksi (all-time, setelah eksklusi CANCELLED).

---

## KPI-08: Active Members

| | |
|---|---|
| **Definisi bisnis** | Jumlah member unik (bukan guest/`NON_MEMBER`) dengan minimal 1 transaksi dalam periode |
| **Grain** | `(customer_id, sale_month)`, `model.vw_customer_order_monthly`, diagregasi `COUNT(DISTINCT customer_id)` per bulan untuk angka bulanan |
| **Rumus SQL** | `COUNT(DISTINCT customer_id)` dari `model.vw_customer_order_monthly` filter bulan tertentu |
| **Inklusi/eksklusi** | `customer_id = 'NON_MEMBER'` (guest checkout / POS tanpa member_id) dikecualikan, karena tidak punya identitas pelanggan yang bisa dilacak |
| **Metric owner** | Tim CRM / Loyalty |
| **Target/ambang** | Tren bulan-ke-bulan, bukan angka absolut tetap |

Sanity check (contoh 5 bulan pertama): Jan-24: 4.917, Feb-24: 4.222,
Mar-24: 5.654, Apr-24: 5.527, Mei-24: 5.253 member aktif.

---

## KPI-09: Repeat Rate

| | |
|---|---|
| **Definisi bisnis** | Proporsi member yang bertransaksi lebih dari 1 kali sepanjang window data (2024-01-01 s.d. 2026-06-30), menunjukkan loyalitas |
| **Grain** | Per `customer_id` (lifetime), `model.vw_customer_lifetime`, diagregasi jadi 1 angka keseluruhan atau dipotong per `join_channel`/`member_tier` via join ke `model.dim_customer` |
| **Rumus SQL** | `100 * SUM(is_repeat_customer::INT) / COUNT(*)` dari `model.vw_customer_lifetime` (`is_repeat_customer = lifetime_orders > 1`) |
| **Inklusi/eksklusi** | Member saja (`NON_MEMBER` dikecualikan, sama seperti KPI-08); "repeat" didefinisikan sebagai >1 **order** (`source_doc_id`) berbeda, bukan >1 baris item |
| **Metric owner** | Tim CRM / Loyalty |
| **Target/ambang** | >70% dianggap sehat untuk database member sebesar ini (hasil aktual 89,2%, jauh di atas ambang, perlu dikonfirmasi ke bisnis apakah ini wajar atau ada bias di data member) |

Sanity check: 39.414 member tercatat bertransaksi, 35.148 (89,2%) di
antaranya repeat (>1 order).

---

## KPI-10: Promo Lift

| | |
|---|---|
| **Definisi bisnis** | Kenaikan/penurunan AOV ketika transaksi memakai promo/voucher dibanding tidak, per kategori. Mengukur efektivitas promo, bukan sekadar volume promo |
| **Grain** | `(category, is_promo)`, dihitung dari `model.vw_sales_metrics` (`is_promo = promo_code != 'NO_PROMO'`) |
| **Rumus SQL** | `SUM(net_amount) / COUNT(DISTINCT source_doc_id)` dikelompokkan per `(category, is_promo)`; lift % = `(AOV_promo - AOV_nonpromo) / AOV_nonpromo * 100` |
| **Inklusi/eksklusi** | Sama seperti KPI-01; `net_amount` sudah bersih dari diskon, jadi lift mengukur *nilai transaksi bersih* yang dibawa promo, bukan nilai kotor sebelum diskon |
| **Metric owner** | Tim Marketing / Promo |
| **Target/ambang** | Lift positif berarti promo efektif menaikkan nilai transaksi. Lift negatif/flat (seperti temuan awal di semua 5 kategori yang dicek, AOV promo justru LEBIH RENDAH dari non-promo) mengindikasikan promo menarik pembeli nilai-kecil, bukan menaikkan basket size, insight untuk Task 5 |

Sanity check (5 kategori pertama, semua menunjukkan AOV promo < non-promo,
pola konsisten yang layak jadi insight Task 5, bukan noise):
```sql
SELECT category, is_promo, count(DISTINCT source_doc_id), round(sum(net_amount)/count(DISTINCT source_doc_id))
FROM model.vw_sales_metrics WHERE category IS NOT NULL GROUP BY 1,2;
-- Beauty & Personal Care: non-promo Rp111.013 vs promo Rp96.555
-- Bedding & Bath:         non-promo Rp312.137 vs promo Rp279.402
-- Elektronik RT:          non-promo Rp624.392 vs promo Rp508.478
-- Fashion:                non-promo Rp224.158 vs promo Rp204.756
-- Home Decor:             non-promo Rp230.829 vs promo Rp196.532
```

---

## Views Implemented (`sql/06_kpi_views.sql`)

| View | Grain | Backs KPI(s) |
|---|---|---|
| `model.vw_sales_metrics` | 1 fact_sales line | 01, 03, 04, 06, 07, 10 |
| `model.vw_returns_metrics` | 1 fact_returns line | 05 |
| `model.vw_achievement_monthly` | (channel, region, year, month) | 02 |
| `model.vw_customer_order_monthly` | (customer_id, month) | 08 |
| `model.vw_customer_lifetime` | customer_id | 09 |

All are `CREATE OR REPLACE VIEW`, zero materialization, always reflect
the current `model.fact_*`/`staging.*` tables, naturally idempotent.
