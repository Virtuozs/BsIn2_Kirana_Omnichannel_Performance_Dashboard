# Decision Statement: KIRANA Omnichannel Performance Intelligence

## Keputusan

Direktur Komersial KIRANA Home & Living harus mengambil **dua keputusan terkait** untuk H2 2026:

1. **Realokasi anggaran promo**, antar-channel (Store / Website / Mobile App / Marketplace), antar-kategori produk, dan antar-mekanisme promo (Ramadan, Clearance, Member Day, App Payday, Mega Sale, Harbolnas).
2. **Penentuan toko/region yang masuk program perbaikan kinerja** H2 2026.

## Pengambil Keputusan

- **Pemilik keputusan (utama):** Direktur Komersial.
- **Pemberi input / terdampak langsung:**
  - Head of Store Operations: kinerja toko, isu operasional (renovasi, dsb.)
  - Head of E-Commerce: kinerja channel online, biaya platform
  - Finance Controller: validasi angka margin dan biaya channel

## Waktu Keputusan

Awal Juli 2026, menggunakan data historis 1 Januari 2024 sampai 30 Juni 2026 (FY2025 penuh + H1 2026), untuk diterapkan pada perencanaan H2 2026.

## Mengapa Keputusan Ini Perlu Data yang Andal

Tim komersial dan finance saat ini punya **angka penjualan yang berbeda** karena data tersebar di sistem terpisah (POS, e-commerce, target Excel) yang belum pernah diintegrasikan. Direktur Komersial meminta **satu sumber angka yang dapat dipercaya** dan *dashboard* yang langsung menjawab pertanyaan di bawah.

## Pemetaan Pertanyaan Bisnis → Keputusan

| # | Pertanyaan Bisnis | Mendukung Keputusan |
|---|---|---|
| 1 | Bagaimana pencapaian *net sales* FY2025 dan H1 2026 terhadap target per *channel*, region, dan toko? | (2) Dasar untuk menilai toko/region mana yang tertinggal dari target |
| 2 | Bagaimana tren, pola musiman, dan pergeseran kontribusi antar-*channel*? | (1) Dasar alokasi ulang anggaran promo ke *channel* yang tumbuh |
| 3 | Kategori, *channel*, dan promo mana yang menekan *gross margin* dan *contribution margin* (setelah biaya *channel*)? | (1) Inti keputusan realokasi, membedakan promo yang menguntungkan vs. yang hanya membeli *revenue* |
| 4 | Seberapa efektif promo (Ramadan, Clearance, Member Day, App Payday, Mega Sale, Harbolnas) dilihat dari kenaikan penjualan dan dampaknya pada margin? | (1) Menentukan mekanisme promo mana yang dilanjutkan/dihentikan |
| 5 | Toko mana yang berkinerja rendah, dan apakah penyebabnya bisnis (tren, kompetisi, renovasi) atau masalah data? | (2) Inti keputusan program perbaikan toko, exclude kasus yang sebenarnya masalah data, bukan kinerja |
| 6 | Bagaimana tingkat dan alasan retur per kategori dan *channel*? | (1) & (2) Retur tinggi bisa mengindikasikan masalah kualitas produk (bukan promo) atau masalah operasional toko |
| 7 | Bagaimana aktivitas dan *repeat purchase member* per *channel*? | (1) Membedakan promo yang membangun loyalitas vs. yang hanya diskon sekali pakai |

## Definisi "Selesai"

*Dashboard* Metabase (dibangun di atas model DuckDB bersih, dengan definisi KPI yang disepakati) dan *insight brief* yang bisa langsung dipakai Direktur Komersial dalam rapat keputusan H2 2026, dengan seluruh angka di laporan sama dengan angka di dashboard.
