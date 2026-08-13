# Daily Alpha Factor Lab — first-pass research

Research-only. Production strategy is unchanged.

## Method
- daily price-derived factors + VIX/VIX3M/10Y real yield only;
- signal at close t predicts returns after t (tradeable from t+1);
- Newey-West HAC t-statistics with lag h-1 for overlapping h-day forward returns;
- development through 2014, validation 2015–2020, holdout 2021+;
- Benjamini-Hochberg FDR correction is computed on development tests;
- holdout statistics are diagnostic and are not used in the selection score;
- exact Swift production engine is used to generate the aligned price/strategy panel.

## Baseline return attribution
- daily linear alpha: 0.00033076
- linear annualized alpha approximation: 8.335%
- beta US: 0.149
- beta Gold: 0.269
- beta China: 0.069
- R²: 0.434

## fwd_us_20 — top development/validation candidates

| factor | family | dev NW t | BH q | val beta | holdout beta | dev rank IC | dev Q5-Q1 |
|---|---|---:|---:|---:|---:|---:|---:|
| eff_gold_60 | trend_efficiency | -2.74 | 0.2335 | -0.00160 | +0.00431 | -0.141 | -0.0176 |
| vol_shanghai_60 | volatility | -2.37 | 0.4012 | -0.00253 | +0.00089 | -0.110 | -0.0256 |
| vol_shanghai_10 | volatility | -2.06 | 0.4140 | -0.00463 | +0.00435 | -0.141 | -0.0205 |
| vol_shanghai_20 | volatility | -2.04 | 0.4140 | -0.00536 | +0.00426 | -0.152 | -0.0254 |
| vol_csi300_60 | volatility | -2.13 | 0.4140 | -0.00275 | -0.00032 | -0.088 | -0.0240 |
| downvol_shanghai_60 | downside_vol | -2.03 | 0.4140 | -0.00267 | +0.00098 | -0.077 | -0.0227 |
| vol_csi300_20 | volatility | -1.78 | 0.4140 | -0.00597 | +0.00223 | -0.131 | -0.0227 |
| vol_csi300_10 | volatility | -1.77 | 0.4140 | -0.00487 | +0.00237 | -0.120 | -0.0171 |
| dd_shanghai_252 | drawdown | 1.92 | 0.4140 | +0.00021 | +0.00168 | +0.026 | +0.0119 |
| dispersion_252 | dispersion | -1.73 | 0.4140 | -0.00354 | -0.00085 | -0.154 | -0.0234 |
| real10_level | real_yield | -1.75 | 0.4140 | -0.00548 | +0.00557 | -0.094 | -0.0106 |
| downvol_csi300_60 | downside_vol | -1.80 | 0.4140 | -0.00261 | +0.00040 | -0.057 | -0.0181 |

## fwd_gold_20 — top development/validation candidates

| factor | family | dev NW t | BH q | val beta | holdout beta | dev rank IC | dev Q5-Q1 |
|---|---|---:|---:|---:|---:|---:|---:|
| real10_level | real_yield | 3.03 | 0.3335 | +0.00378 | +0.00782 | +0.190 | +0.0328 |
| ma_dist_gold_60 | trend | -2.43 | 0.5812 | -0.00181 | +0.00257 | -0.115 | -0.0212 |
| mom_gold_20 | momentum | -2.40 | 0.5812 | -0.00311 | +0.00156 | -0.083 | -0.0177 |
| ma_dist_gold_20 | trend | -1.95 | 0.9947 | -0.00343 | -0.00218 | -0.062 | -0.0090 |
| mom_gold_10 | momentum | -1.71 | 0.9947 | -0.00289 | -0.00290 | -0.048 | -0.0068 |
| ma_dist_gold_120 | trend | -1.52 | 0.9947 | -0.00222 | +0.00440 | -0.080 | -0.0076 |
| vix3m_level | vix_term | 1.64 | 0.9947 | +0.00633 | -0.00684 | +0.169 | +0.0153 |
| eff_sp500_60 | trend_efficiency | -2.91 | 0.3335 | +0.00689 | +0.00105 | -0.158 | -0.0238 |
| vol_sp500_60 | volatility | 1.39 | 0.9947 | +0.00306 | -0.00370 | +0.099 | +0.0049 |
| vol_nasdaq_60 | volatility | 1.30 | 0.9947 | +0.00282 | -0.00289 | +0.094 | +0.0003 |
| mom_gold_60 | momentum | -1.30 | 0.9947 | -0.00311 | +0.00296 | -0.064 | -0.0083 |
| rel_us_china_20 | relative_strength | 1.04 | 0.9947 | +0.00080 | -0.00370 | +0.080 | +0.0102 |

## fwd_portfolio_20 — top development/validation candidates

| factor | family | dev NW t | BH q | val beta | holdout beta | dev rank IC | dev Q5-Q1 |
|---|---|---:|---:|---:|---:|---:|---:|
| ma_dist_shanghai_252 | trend | 3.98 | 0.0018 | +0.00060 | +0.00323 | +0.254 | +0.0215 |
| mom_shanghai_120 | momentum | 4.01 | 0.0018 | +0.00141 | +0.00398 | +0.237 | +0.0204 |
| dd_csi300_120 | drawdown | 3.94 | 0.0019 | +0.00095 | +0.00270 | +0.144 | +0.0174 |
| ma_dist_csi300_252 | trend | 3.85 | 0.0024 | +0.00074 | +0.00281 | +0.268 | +0.0232 |
| rel_us_china_252 | relative_strength | -3.77 | 0.0027 | -0.00017 | +0.00019 | -0.280 | -0.0198 |
| mom_csi300_120 | momentum | 3.75 | 0.0027 | +0.00171 | +0.00324 | +0.252 | +0.0215 |
| dd_shanghai_120 | drawdown | 3.80 | 0.0026 | +0.00108 | +0.00216 | +0.122 | +0.0171 |
| ma_dist_shanghai_120 | trend | 3.72 | 0.0028 | +0.00036 | +0.00399 | +0.180 | +0.0186 |
| ma_dist_csi300_120 | trend | 3.67 | 0.0030 | +0.00033 | +0.00372 | +0.196 | +0.0207 |
| rel_gold_china_120 | relative_strength | -3.58 | 0.0040 | -0.00160 | +0.00131 | -0.230 | -0.0201 |
| rel_us_china_120 | relative_strength | -3.45 | 0.0053 | -0.00309 | -0.00126 | -0.192 | -0.0177 |
| dd_csi300_60 | drawdown | 2.89 | 0.0278 | +0.00018 | +0.00378 | +0.083 | +0.0107 |

## fwd_us_minus_gold_20 — top development/validation candidates

| factor | family | dev NW t | BH q | val beta | holdout beta | dev rank IC | dev Q5-Q1 |
|---|---|---:|---:|---:|---:|---:|---:|
| real10_level | real_yield | -3.88 | 0.0188 | -0.00926 | -0.00224 | -0.214 | -0.0433 |
| eff_sp500_20 | trend_efficiency | 2.36 | 0.6381 | +0.00041 | +0.00299 | +0.081 | +0.0183 |
| dispersion_10 | dispersion | -2.12 | 0.7693 | -0.00386 | +0.00491 | -0.071 | -0.0132 |
| dd_shanghai_120 | drawdown | 2.05 | 0.7926 | +0.00493 | +0.00248 | +0.155 | +0.0303 |
| dd_csi300_120 | drawdown | 1.97 | 0.7926 | +0.00434 | +0.00295 | +0.127 | +0.0287 |
| vol_shanghai_10 | volatility | -1.84 | 0.7926 | -0.00801 | +0.00422 | -0.136 | -0.0197 |
| downvol_shanghai_60 | downside_vol | -1.85 | 0.7926 | -0.00500 | +0.00570 | -0.121 | -0.0260 |
| vol_shanghai_60 | volatility | -2.01 | 0.7926 | -0.00402 | +0.00433 | -0.093 | -0.0240 |
| downvol_shanghai_20 | downside_vol | -1.70 | 0.7926 | -0.01185 | +0.00761 | -0.140 | -0.0217 |
| downvol_shanghai_120 | downside_vol | -1.72 | 0.7926 | -0.00651 | -0.00334 | -0.103 | -0.0260 |
| vol_shanghai_20 | volatility | -1.56 | 0.7926 | -0.00884 | +0.00561 | -0.133 | -0.0239 |
| dd_shanghai_252 | drawdown | 1.53 | 0.7926 | +0.00657 | +0.00349 | +0.078 | +0.0098 |

## Event-level de-risk explainability

| event type | horizon | factor | n | beta/sd | t | R² | Spearman |
|---|---:|---|---:|---:|---:|---:|---:|
| all_derisk | 20 | mom_gold_60 | 78 | +0.0045 | +2.80 | 0.068 | +0.230 |
| non_us_derisk | 20 | mom_nasdaq_60 | 30 | -0.0062 | -2.78 | 0.158 | -0.238 |
| all_derisk | 20 | chg_real10_20 | 77 | -0.0037 | -2.43 | 0.045 | -0.242 |
| non_us_derisk | 20 | mom_gold_60 | 30 | +0.0058 | +2.34 | 0.134 | +0.298 |
| all_derisk | 60 | chg_vix_5 | 77 | +0.0048 | +2.16 | 0.047 | +0.271 |
| us_derisk | 20 | chg_real10_20 | 48 | -0.0040 | -2.08 | 0.046 | -0.187 |
| non_us_derisk | 20 | vol_nasdaq_20 | 30 | -0.0032 | -2.00 | 0.042 | -0.307 |
| us_derisk | 60 | chg_vix_5 | 47 | +0.0059 | +1.94 | 0.052 | +0.319 |
| non_us_derisk | 60 | vix_level | 30 | -0.0034 | -1.90 | 0.052 | +0.003 |
| us_derisk | 20 | mom_gold_60 | 48 | +0.0045 | +1.86 | 0.059 | +0.233 |
| non_us_derisk | 60 | vol_nasdaq_20 | 30 | -0.0032 | -1.81 | 0.046 | -0.097 |
| non_us_derisk | 20 | vix_level | 30 | -0.0028 | -1.57 | 0.032 | -0.121 |
| non_us_derisk | 20 | chg_real10_20 | 29 | -0.0033 | -1.45 | 0.048 | -0.321 |
| us_derisk | 20 | vix_term_ratio | 42 | +0.0019 | +1.43 | 0.009 | +0.283 |
| all_derisk | 20 | mom_nasdaq_60 | 78 | -0.0023 | -1.33 | 0.017 | -0.077 |
| all_derisk | 60 | vol_nasdaq_20 | 77 | -0.0022 | -1.25 | 0.010 | -0.005 |
| us_derisk | 60 | chg_real10_20 | 47 | -0.0044 | -1.13 | 0.028 | -0.065 |
| all_derisk | 20 | vol_nasdaq_20 | 78 | -0.0015 | -1.12 | 0.007 | -0.114 |
| us_derisk | 20 | breadth_20 | 48 | -0.0026 | -1.05 | 0.020 | -0.107 |
| all_derisk | 60 | vix_level | 77 | -0.0018 | -0.99 | 0.006 | +0.038 |

## Promotion rule
A factor is not promoted into a Swift strategy overlay from this table alone. It must also pass redundancy/orthogonalization, walk-forward economic tests in the exact App engine, costs, drawdown constraints, and robustness/ablation tests.
