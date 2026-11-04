# UAS Business Intelligence Systems: Paket Data KIRANA Home & Living

Program Studi Sains Data, Universitas Cakrawala
Ujian Akhir Semester Blok A, Oktober 2026

Paket ini berisi raw data penjualan KIRANA Home & Living, peritel omnichannel dengan 18 toko serta kanal Website, Mobile App, dan Marketplace. Periode data 1 Januari 2024 sampai 30 Juni 2026. Seluruh nama perusahaan, toko, dan pelanggan di dalamnya fiktif.

File di folder `raw_data/` adalah hasil export dari beberapa sistem yang berbeda dan belum pernah diintegrasikan. Jangan mengubah file secara manual. Seluruh proses pembersihan dan pemodelan dilakukan dengan SQL di DuckDB, lalu hasilnya divisualisasikan di Metabase.

## Isi Paket

| File | Sumber | Keterangan |
|---|---|---|
| `sales_pos_transactions.csv` | POS toko | 264.420 baris transaksi toko per item |
| `sales_online_orders.csv` | Platform e-commerce | 209.626 baris order Website, Mobile App, dan Marketplace per item |
| `products.csv` | Master produk | SKU, kategori, merek, harga jual dan HPP per 30 Juni 2026 |
| `product_cost_history.csv` | Finance | Riwayat HPP per SKU beserta masa berlakunya |
| `stores.csv` | Master toko | 18 toko beserta region saat ini |
| `store_region_history.csv` | Store Operations | Riwayat perpindahan region toko |
| `store_events.csv` | Store Operations | Kejadian operasional toko, seperti renovasi |
| `customers.csv` | CRM | 42.320 profil member, berisi data pribadi |
| `returns.csv` | Customer Service | 18.090 retur per item beserta alasannya |
| `promotions.csv` | Marketing | Kalender promo, cakupan channel dan kategori, diskon, anggaran |
| `channel_fee_rates.csv` | Finance | Biaya per channel dalam persen net sales, beserta masa berlakunya |
| `sales_targets_2025_2026.xlsx` | FP&A | Target net sales bulanan 2025 dan semester I 2026, serta target gross margin |
| `pos_sync_log.csv` | IT | Status sinkronisasi harian data POS ke kantor pusat |

## Kamus Data

### sales_pos_transactions.csv

| Kolom | Keterangan |
|---|---|
| trx_id, line_no | Nomor struk dan nomor baris item di dalam struk |
| trx_datetime | Waktu transaksi, format `YYYY-MM-DD HH:MM:SS` |
| store_code | Kode toko |
| cashier_id | ID kasir |
| member_id | ID member. Kosong berarti pembeli bukan member |
| sku | Kode produk |
| qty | Jumlah unit. Nilai negatif adalah baris pembatalan (void) oleh kasir |
| unit_price | Harga per unit sebelum diskon |
| discount_amount | Total diskon untuk baris tersebut (Rp) |
| promo_code | Kode promo yang dipakai |
| payment_type | Metode pembayaran |

### sales_online_orders.csv

| Kolom | Keterangan |
|---|---|
| order_no, line_no | Nomor order dan nomor baris item |
| order_date | Waktu order, format `DD/MM/YYYY HH:MM` |
| sales_channel | Website, Mobile App, atau Marketplace |
| customer_id | ID member, formatnya sama dengan `customers.customer_id` |
| ship_city, ship_province | Kota dan provinsi tujuan pengiriman |
| sku, qty | Kode produk dan jumlah unit |
| item_price | Harga per unit sebelum voucher |
| voucher_code, voucher_amount | Kode dan nilai voucher untuk baris tersebut (Rp) |
| payment_method | Metode pembayaran |
| order_status | COMPLETED atau CANCELLED |

### File pendukung

- `products.csv` hanya memuat harga jual dan HPP terakhir. Untuk periode sebelumnya gunakan `product_cost_history.csv`. Nilai `valid_to = 9999-12-31` berarti masih berlaku.
- Kolom `region` di `stores.csv` adalah region saat ini. Perubahan region sebelumnya ada di `store_region_history.csv`.
- `original_trx_id` di `returns.csv` merujuk ke `trx_id` (toko) atau `order_no` (online).
- Di `promotions.csv`, `channel_scope` berisi ALL atau nama channel, `category_scope` berisi ALL atau daftar kategori yang dipisahkan titik koma, dan `member_only = True` berarti promo hanya berlaku untuk member.
- `channel_fee_rates.csv` berisi MDR pembayaran di toko, biaya payment gateway untuk Website dan Mobile App, serta komisi dan biaya layanan Marketplace.
- Di `sales_targets_2025_2026.xlsx`, target Store ditetapkan per region, sedangkan target online ditetapkan per channel secara nasional. Header tabel berada di baris ketiga. Target gross margin ada di sheet `Target GM`.
- `sync_status` di `pos_sync_log.csv` berisi SUCCESS, FAILED (data hari itu tidak terkirim ke pusat), atau STORE_CLOSED.

## Region

Region resmi yang dipakai perusahaan: Jabodetabek, Jawa Barat, Jateng & DIY, Jawa Timur, Bali & Nusa Tenggara, dan Sumatera. Untuk order online, gunakan provinsi tujuan pengiriman bila analisis per wilayah diperlukan. Provinsi di luar keenam region tersebut dikelompokkan sebagai Lainnya.

## Alat yang Digunakan

**DuckDB** dipakai untuk memuat file mentah, membersihkan data, membangun star schema, menjalankan uji kualitas data, dan menyimpan view metrik. DuckDB dapat dipakai lewat CLI (`duckdb`) atau Python (`pip install duckdb`). File CSV dibaca dengan `read_csv`, sedangkan file target Excel dibaca dengan `read_xlsx` dari extension `excel` (`INSTALL excel; LOAD excel;`). Simpan hasilnya dalam satu file database, misalnya `kirana.duckdb`.

**Metabase** dipakai untuk dashboard. Jalankan Metabase secara self-hosted (file JAR dengan Java 21 atau Docker) dan pasang driver DuckDB (`duckdb.metabase-driver.jar` dari MotherDuck-Open-Source/metabase_duckdb_driver di GitHub) di folder `plugins`. Setelah itu tambahkan file `kirana.duckdb` sebagai database di Admin > Databases. Metabase Cloud tidak dapat dipakai karena belum mendukung driver DuckDB.

Hal yang perlu diperhatikan:

- File DuckDB hanya dapat ditulis oleh satu proses. Saat menjalankan ulang skrip SQL, matikan Metabase atau gunakan koneksi read-only di Metabase.
- Bila driver DuckDB tidak dapat dipasang di komputer Anda, hasil model boleh diekspor ke PostgreSQL lalu dihubungkan ke Metabase. Jelaskan pilihan ini di laporan.

## Catatan

Data ini belum dibersihkan dan memang mengandung masalah kualitas data yang lazim ditemui pada sistem sumber. Menemukan, mengukur, dan memutuskan penanganannya termasuk bagian dari penilaian.

Susun skrip SQL secara berurutan (misalnya load, staging, model, uji kualitas data, metrik) dan pastikan seluruh skrip dapat dijalankan ulang dari folder `raw_data` dengan hasil yang sama.

Pertanyaan teknis terkait paket data dapat disampaikan kepada dosen pengampu.
