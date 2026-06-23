# 006: New payoff source search

## Constraint

User explicitly rejected parameter-fitting. This spike searched for genuinely different payoff sources:

- managed-futures / multi-asset trend overlay;
- defensive carry / long-history funds;
- active multi-asset fund trend + carry;
- crisis hedge overlay;
- defensive rates/metals/FX trend overlay.

All checks used real historical data, no BTC, T-1 signal / T execution where applicable, and full-cycle validation.

## Data probed

### Yahoo adjusted close funds / ETFs

Long-history data was available for examples including:

- SPY, QQQ, XLK;
- VFINX, VUSTX, VFISX, VFITX, VBMFX;
- FPACX, PRWCX, VWINX, VWELX, OAKBX, DODIX, PTTRX, MERFX;
- PCRIX, RYMFX, AQMIX, PQTIX where shorter histories apply.

### Yahoo continuous futures

Long-history daily data was available from ~2000/2001 for:

- metals: GC=F, SI=F, HG=F;
- energy: CL=F;
- grains/softs/livestock: ZC=F, ZS=F, ZW=F, KC=F, SB=F, CT=F, CC=F, LE=F, HE=F;
- rates: ZB=F, ZN=F, ZF=F, ZT=F;
- equity: ES=F, NQ=F;
- FX: 6E=F, 6J=F, 6B=F, 6A=F, 6C=F.

Prices were converted to CNY with the existing `usd_per_cny` series where needed.

## Findings

### Standalone new sources failed the main objective

- Naive multi-asset CTA: ~4–5% annualized with 30%+ max drawdown.
- Long-history active/balanced funds: some had 8–10% annualized, but 30%+ drawdowns.
- Active fund + carry switching: ~4.2% annualized / ~14.9% drawdown.
- Crisis hedge overlay activated only after broad risk-off: reduced 2008 but hurt 2020/2022 and lowered full-cycle return.

### Best useful mechanism: overlay, not replacement

The only useful improvement came from keeping the existing core strategy intact and adding a small futures trend overlay.

Baseline core on aligned 2002-01-04..2026-06-19:

- Full: 7.32% annualized / 9.25% max drawdown.

Best conservative overlay candidates:

1. `N_core_plus_cta_overlay_0.10`
   - Full: 7.73% / 9.39%.
   - Post-2020: 9.33% / 8.90%.
   - Last 10Y: 7.43% / 8.90%.
   - 2024+: 17.80% / 6.57%.

2. `R_core_plus_defensive_trend_overlay_0.20`
   - Full: 7.66% / 9.36%.
   - Post-2020: 9.03% / 9.36%.
   - Last 10Y: 7.50% / 9.36%.
   - 2024+: 17.50% / 6.59%.

Higher overlays improve return but exceed the desired drawdown band:

- `N_core_plus_cta_overlay_0.20`: 8.14% / 10.74%.
- `O_core_plus_cta_gated_overlay_0.30`: 8.01% / 10.94%.
- `R_core_plus_defensive_trend_overlay_0.30`: 7.83% / 10.07%.

## Additional search: cash-plus defense + small CTA overlay

A second pass found a stronger mechanism: do not merely add CTA. First turn part of idle cash into a guarded cash-plus sleeve, then add a very small CTA overlay.

New data source:

- `OSTIX` (Osterweis Strategic Income): available from 2002-09, standalone ~6.10% annualized / ~10.06% max drawdown.
- `VFISX`: short-term treasury fund from 2001, used as fallback and pre-OSTIX bridge.
- `RPHYX`: ultra-short fund from 2010, used only as a later fallback when healthy.

Fixed logic:

- Keep the existing core strategy unchanged.
- Allocate only one-third of otherwise idle cash to a guarded cash-plus sleeve; leave the rest as true cash.
- Cash-plus selector: OSTIX only when its own NAV trend/drawdown are healthy; otherwise VFISX/RPHYX fallback.
- Add a small 10% CTA overlay from the managed-futures sleeve.

Best result:

`T_cashplus_third_plus_cta_0.10`

- Full: 8.27% annualized / 9.84% max drawdown.
- Post-2020: 9.46% / 9.28%.
- Last 10Y: 7.75% / 9.28%.
- 2024+: 17.82% / 6.82%.
- 2002-2012: 8.68% / 9.36%.
- 2013-2023: 5.75% / 9.84%.

Compared with the aligned baseline core:

- Baseline: 7.32% / 9.25%.
- New candidate: 8.27% / 9.84%.

This is the best full-cycle candidate found so far that remains below 10% max drawdown.

## Verdict after product-fit correction: REJECT AS MAIN STRATEGY

The cash-plus + CTA result is numerically useful but off-theme for AssetTimeMachine's current strategy direction. It drifts away from the user's intended product story around gold and Nasdaq.

Do not present this as a main strategy candidate.

It may remain only as background research for future institutional-style portfolio tooling, because it requires unrelated assets:

1. cash-plus / short-duration credit fund proxy;
2. managed-futures / CTA overlay.

For the current product, future searches should stay centered on gold + Nasdaq as holdings/story anchors. External assets may be used only as signals if necessary, not as the strategy's visible core allocation.
