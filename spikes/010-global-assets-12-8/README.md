# 010: Expanded global assets for 12% annualized / 8% max drawdown

## User request

The user rejected the gold/Nasdaq-only results as far below the original standard and explicitly allowed adding more selectable assets:

```text
S&P 500, Nikkei, Shanghai Composite, CSI 300, etc. can all be added.
```

Target remains strict:

```text
Annualized return >= 12%
Max drawdown <= 8%
```

User preference remains: no BTC/crypto unless explicitly changed.

## Data sources

### Existing AssetTimeMachine API

Used:

```text
https://api.flyingrtx.com/api/v1/money/public/history
```

Non-crypto assets available from the API:

```text
gold_cny
nasdaq_composite
sp500
dow_jones
nikkei225
shanghai_composite
shenzhen_component
csi300
chinext
hang_seng
usd_per_cny
```

USD-priced assets were converted using the app's existing convention from `scripts/find_optimal_strategy.py`:

```text
CNY value = USD price / usd_per_cny
```

### External Yahoo ETF branch

Also tested free Yahoo adjusted-close ETF/proxy data:

Core ETF branch:

```text
QQQ, SPY, DIA, EWJ, FXI, EEM, EFA, GLD, TLT, IEF, SHY, UUP, DBC, VNQ
```

Levered ETF branch, separately marked due shorter coverage and leverage:

```text
QLD, SSO, TQQQ, UPRO, TMF, UBT
```

## API asset static baselines

Full available histories:

```text
gold_cny:           10.61% / 44.32%
chinext:             9.62% / 69.74%    starts 2010
nasdaq_composite:    6.65% / 79.23%
shenzhen_component:  5.92% / 70.98%
sp500:               5.61% / 63.40%
csi300:              5.56% / 72.30%
dow_jones:           5.01% / 57.94%
shanghai_composite:  4.12% / 71.98%
nikkei225:           2.56% / 72.01%
hang_seng:           1.25% / 65.18%
```

Static assets do not reach 12/8. The target requires strong rotation/risk control.

## Branch A — API global index universe, 2002+ core

Assets:

```text
gold_cny
nasdaq_composite
sp500
dow_jones
nikkei225
shanghai_composite
shenzhen_component
csi300
hang_seng
```

Coverage:

```text
2002-01-04 to 2026-06-18
```

Mechanisms tested:

- top-k VAA-style momentum;
- top-k accelerated dual momentum;
- PAA/GPM-style breadth risk budget;
- EAA-style momentum/volatility/correlation weighting;
- global risk-on/risk-off state machine;
- crisis alpha / gold reentry logic.

Best return candidate:

```text
TOP3_vaa_volpen
Full:      12.05% / 48.08%
Post-2020: 9.51% / 16.97%
Last 10Y:  9.48% / 17.91%
Latest:    30.1% Nasdaq / 34.3% Nikkei / 33.5% Shenzhen / 2.1% cash
```

This reaches 12% annualized, but drawdown is unusable.

Best lower-drawdown mechanism in this branch:

```text
GLOBAL_STATE_MACHINE
Full:      5.48% / 18.80%
Post-2020: 1.63% / 18.80%
Last 10Y:  2.07% / 18.80%
```

Still nowhere near 12/8.

Verdict:

```text
FAIL.
```

The expanded API equity/index universe can produce 12% return only by taking 35%-50% drawdown.

## Branch B — API global index universe including Chinext, 2010+

Assets:

```text
gold_cny
nasdaq_composite
sp500
dow_jones
nikkei225
shanghai_composite
shenzhen_component
csi300
chinext
hang_seng
```

Coverage:

```text
2010-06-01 to 2026-06-18
```

Best static return baselines:

```text
Nasdaq:   16.37% / 30.88%
S&P 500:  12.64% / 32.89%
Dow:      10.57% / 35.81%
Nikkei:    9.85% / 29.86%
Chinext:   9.38% / 69.39%
```

Best strategy candidates remained poor:

```text
TOP1_adm_tempered: 9.15% / 42.14%
EAA_like_top2:     8.01% / 38.52%
PAA_top1:          7.86% / 40.52%
```

Verdict:

```text
FAIL.
```

Even with Chinext, trend/momentum rotation does not control drawdown.

## Branch C — single-asset technical signals

Tested Bollinger/MA/consecutive-up/down signal families, excluding BTC/ETH:

```text
gold, Nasdaq, S&P, Dow, Nikkei, Shanghai, Shenzhen, CSI 300, Chinext, Hang Seng
```

Result:

```text
No single-asset signal reached 12/8.
```

High-return candidates were not high enough; low-drawdown candidates were cash-like.

Top by annualized from the tested signal grid was only around:

```text
Shanghai technical signal: ~2.89% / 10.02%
```

Verdict:

```text
FAIL.
```

## Branch D — external core ETFs

Core Yahoo ETF branch:

```text
QQQ, SPY, DIA, EWJ, FXI, EEM, EFA, GLD, TLT, IEF, SHY, UUP, DBC, VNQ
```

Coverage was limited by UUP to:

```text
2007-03-01 to 2026-06-18
```

Best tested ETF rotation:

```text
TOP3: 5.14% / 30.10%
TOP2: 3.44% / 33.06%
```

Risk-safe rotation was hurt by long bond / dollar / China ETF regimes and did not work.

Verdict:

```text
FAIL.
```

## Branch E — external levered ETF branch, 2011+

Levered branch tested:

```text
TQQQ, UPRO, QLD, SSO, TMF, UBT, plus QQQ/SPY/GLD/TLT/IEF/SHY
```

Coverage:

```text
2011-01-03 to 2026-06-17/18
```

### Levered growth + bond/gold defense

Naive levered/bond/gold rotation failed badly. TMF/TLT-like defense is not safe across 2022+:

```text
Best overall from first levered branch: ~4.57% / 53.90%
```

### TQQQ/UPRO/QLD/SSO + SHY/cash defense

A focused grid with only SHY/cash/GLD defense improved behavior but still failed 12/8.

Best under 12% drawdown:

```text
T24987: 7.38% / 11.26%
```

Best overall:

```text
T11751: 9.21% / 15.73%
```

No passing candidate:

```text
PASS_COUNT = 0
```

Verdict:

```text
FAIL.
```

Even with modest leverage, simple trend/risk switches did not get close to 12/8.

## Branch F — prior managed-futures / cash-plus research

Existing `006-new-payoff-source` had already tested non-BTC new payoff sources:

- managed futures / CTA overlay;
- cash-plus / short-duration credit proxy;
- active multi-asset funds;
- futures trend overlay.

Best prior result:

```text
T_cashplus_third_plus_cta_0.10
Full:      8.27% / 9.84%
Post-2020: 9.46% / 9.28%
Last 10Y:  7.75% / 9.28%
```

Verdict:

```text
Still below 12/8.
```

## Honest status

After allowing:

```text
S&P 500
Dow
Nikkei
Shanghai
Shenzhen
CSI 300
Chinext
Hang Seng
Gold
Nasdaq
external ETFs
bond ETFs
gold ETFs
commodity ETF
modest levered ETFs
cash/SHY defense
```

No tested candidate reached:

```text
12% annualized / 8% max drawdown
```

The only branch that touched 12% annualized was API global VAA-style top-3 momentum:

```text
12.05% / 48.08%
```

So the remaining problem is not lack of equity markets. It is that the available long-only/index-like return sources have too much crash risk, and reducing risk cuts return far below 12%.

## What likely has to be allowed next

To honestly pursue 12/8, the next branch must introduce one of the following capabilities, not merely more long-only equity indices:

1. **True long/short or trend-following futures with controlled notional**
   Long-only index ETFs are not enough. Need short equity/rates/FX/commodities or managed-futures style P&L.

2. **Options / explicit convex crisis hedge**
   Needed to cut drawdowns without giving up too much trend upside.

3. **A genuinely predictive macro/liquidity signal**
   Current close-price-only momentum/MA/Bollinger/risk-breadth signals do not have enough edge.

4. **Accept BTC/crypto or other high-volatility satellite**
   Not recommended unless user explicitly overturns the no-BTC preference.

5. **Relax one side of the target**
   Current best non-crypto, long-only-ish results cluster around either:
   - 10%-12% return with 35%-50% drawdown, or
   - 6%-9% return with 10%-16% drawdown.

## Files

- Main API global index search: `spikes/010-global-assets-12-8/global_assets_12_8_search.py`
- Single-asset signal search: `spikes/010-global-assets-12-8/single_asset_signal_search.py`
- External ETF search: `spikes/010-global-assets-12-8/external_etf_12_8.py`
- Levered ETF search: `spikes/010-global-assets-12-8/levered_growth_defense_search.py`
- TQQQ/SHY focused timing search: `spikes/010-global-assets-12-8/tqqq_shy_timing_search.py`

Logs / JSON:

- `/tmp/atm_global_assets_12_8_v2.log`
- `/tmp/atm_global_assets_12_8_search.json`
- `/tmp/atm_single_asset_signal_12_8_by_ann.log`
- `/tmp/atm_external_etf_12_8.log`
- `/tmp/atm_external_etf_12_8.json`
- `/tmp/atm_levered_growth_defense_12_8.log`
- `/tmp/atm_levered_growth_defense_12_8.json`
- `/tmp/atm_tqqq_shy_timing_12_8.log`
- `/tmp/atm_tqqq_shy_timing_12_8.json`
