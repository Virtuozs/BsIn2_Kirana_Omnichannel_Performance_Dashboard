# Task 5: Insight, Data Story & Rekomendasi: Notes

## Deliverables

- `evidence/task5_insights/insight_brief.pdf`: 4-page insight brief for
  Direktur Komersial (within the 6-page max), rendered from
  `artifacts/task5/insight_brief.html` via WeasyPrint
- Metabase dashboard **Storyline** tab (dashboard id 2, 5th tab), same
  6 insights + recommendations summary, cross-referencing the other 4
  tabs' charts directly
- `evidence/task4_dashboard/dashboard_export.pdf`: updated to include
  all 5 tabs (4 analytical + storyline)

## How each requirement was met

- **6 quantified insights** (exceeds the 4-6 minimum), each with an
  assertive title stating the finding, not a topic label (e.g. "Promo
  yang berjalan justru MENGECILKAN nilai transaksi" rather than "Analisis
  Promo")
- **Real business event vs data issue, explicitly tagged**: 5 of 6
  insights are tagged "Kejadian Bisnis Nyata" (verified against a second
  independent source, e.g. insight #2's channel-fee finding is
  cross-checked against the actual commission-rate change date in
  `staging.stg_channel_fee_rates`, not just the aggregate numbers);
  1 insight (#5) is explicitly tagged "Isu Data/Governance" and the
  brief states plainly it should **not** be used for store reward/
  punishment decisions until clarified
- **Recommendations for both decisions**, each with impact estimate,
  risk, and what additional data could change the recommendation:
  - Promo reallocation: minimum-purchase mechanism for the two
    categories with the largest AOV cannibalization, reduced Marketplace
    promo subsidy, keep Ramadan Sale as a measurable seasonal exception
  - Store/region program: Jawa Barat + Sumatera prioritized (both
    persistently below target across 2 full periods, at every store in
    the region, not one outlier), paired with an explicit caution to
    validate whether the *targets* themselves are realistic before
    assuming store execution is at fault

## Numbers behind the brief (reproducible)

All figures were computed directly against `db/kirana.duckdb`'s
`model.vw_sales_metrics` / `vw_achievement_monthly` / `vw_returns_metrics`
(Task 3's KPI views). The exact queries are inline comments in
`artifacts/task5/insight_brief.html`'s source where not otherwise obvious,
and every number traces back to a KPI already defined in
`artifacts/task3/kpi_dictionary.md`. No new metrics were invented for
this brief; it only re-slices existing KPI views by category/channel/
region/time.
