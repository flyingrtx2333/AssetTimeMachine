# Daily Alpha Factor Lab — incremental regression

Research-only. Production strategy unchanged.

## Static return attribution

- annualized intercept alpha (linear approximation): 8.335%
- alpha Newey-West t: 6.31
- beta US: 0.149 (t=14.68)
- beta Gold: 0.269 (t=20.19)
- beta China: 0.069 (t=8.63)
- R²: 0.434

## fwd_portfolio_20

| factor | family | AR1 | partial R² dev | cond NW t | BH q | ΔR² val | ΔR² holdout |
|---|---|---:|---:|---:|---:|---:|---:|
| eff_nasdaq_60 | trend_efficiency | 0.951 | 0.0170 | -2.63 | 0.4141 | -0.0217 | +0.0022 |
| vix_level | vix | 0.977 | 0.0103 | +1.88 | 0.5479 | +0.0489 | +0.0116 |
| vix_term_ratio | vix_term | 0.926 | 0.0141 | +1.77 | 0.5479 | +0.0408 | +0.0247 |
| vol_gold_120 | volatility | 0.999 | 0.0107 | +1.90 | 0.5479 | +0.0343 | -0.0164 |
| downvol_sp500_120 | downside_vol | 0.999 | 0.0172 | +2.21 | 0.5479 | +0.0260 | +0.0077 |
| vol_sp500_120 | volatility | 0.999 | 0.0160 | +2.08 | 0.5479 | +0.0221 | +0.0055 |
| vol_nasdaq_120 | volatility | 0.999 | 0.0114 | +1.76 | 0.5479 | +0.0193 | +0.0113 |
| vix3m_level | vix_term | 0.986 | 0.0135 | +1.63 | 0.6109 | +0.0397 | +0.0142 |
| breadth_20 | breadth | 0.869 | 0.0052 | -1.59 | 0.6109 | +0.0081 | +0.0104 |
| rel_gold_china_252 | relative_strength | 0.998 | 0.0084 | -1.27 | 0.6988 | +0.0221 | -0.0053 |
| breadth_60 | breadth | 0.935 | 0.0037 | -1.24 | 0.6988 | +0.0169 | +0.0015 |
| dd_csi300_252 | drawdown | 0.996 | 0.0029 | -1.26 | 0.6988 | -0.0056 | -0.0012 |
| eff_csi300_120 | trend_efficiency | 0.988 | 0.0094 | -1.35 | 0.6988 | -0.0273 | -0.0064 |
| eff_shanghai_120 | trend_efficiency | 0.986 | 0.0076 | -1.27 | 0.6988 | -0.0297 | -0.0063 |
| dispersion_60 | dispersion | 0.967 | 0.0067 | -1.28 | 0.6988 | -0.0465 | +0.0089 |
| rel_gold_china_120 | relative_strength | 0.994 | 0.0026 | -0.78 | 0.7361 | +0.0222 | +0.0001 |
| rel_us_china_252 | relative_strength | 0.998 | 0.0055 | -1.05 | 0.7361 | +0.0205 | -0.0083 |
| vix_z252 | vix | 0.940 | 0.0032 | +0.96 | 0.7361 | +0.0176 | +0.0218 |

## fwd_us_20

| factor | family | AR1 | partial R² dev | cond NW t | BH q | ΔR² val | ΔR² holdout |
|---|---|---:|---:|---:|---:|---:|---:|
| eff_csi300_120 | trend_efficiency | 0.988 | 0.0161 | -2.86 | 0.0588 | +0.0011 | +0.0088 |
| breadth_20 | breadth | 0.869 | 0.0173 | -2.76 | 0.0588 | -0.0178 | +0.0164 |
| dispersion_120 | dispersion | 0.989 | 0.0175 | -2.66 | 0.0588 | -0.0235 | +0.0021 |
| dispersion_252 | dispersion | 0.997 | 0.0390 | -3.19 | 0.0588 | -0.0249 | +0.0091 |
| vol_csi300_60 | volatility | 0.998 | 0.0399 | -2.63 | 0.0588 | -0.0779 | -0.0002 |
| vol_shanghai_60 | volatility | 0.998 | 0.0468 | -2.85 | 0.0588 | -0.0966 | -0.0040 |
| downvol_shanghai_120 | downside_vol | 0.999 | 0.0466 | -2.72 | 0.0588 | -0.1623 | +0.0081 |
| downvol_csi300_120 | downside_vol | 0.999 | 0.0434 | -2.58 | 0.0590 | -0.1380 | +0.0094 |
| eff_gold_60 | trend_efficiency | 0.950 | 0.0163 | -2.50 | 0.0661 | -0.0057 | -0.0287 |
| downvol_shanghai_60 | downside_vol | 0.996 | 0.0308 | -2.46 | 0.0661 | -0.0914 | +0.0011 |
| mom_sp500_5 | momentum | 0.748 | 0.0080 | -2.20 | 0.0886 | -0.0102 | +0.0039 |
| vol_shanghai_10 | volatility | 0.961 | 0.0274 | -2.22 | 0.0886 | -0.0108 | -0.0172 |
| vol_shanghai_20 | volatility | 0.988 | 0.0314 | -2.28 | 0.0886 | -0.0172 | -0.0171 |
| breadth_10 | breadth | 0.793 | 0.0100 | -2.25 | 0.0886 | -0.0178 | +0.0068 |
| downvol_csi300_60 | downside_vol | 0.996 | 0.0260 | -2.24 | 0.0886 | -0.0688 | +0.0018 |
| mom_gold_10 | momentum | 0.890 | 0.0146 | -2.16 | 0.0934 | -0.0265 | +0.0103 |
| mom_nasdaq_5 | momentum | 0.760 | 0.0077 | -2.06 | 0.0980 | -0.0103 | +0.0024 |
| mom_gold_5 | momentum | 0.791 | 0.0077 | -2.09 | 0.0980 | -0.0123 | +0.0039 |

## fwd_gold_20

| factor | family | AR1 | partial R² dev | cond NW t | BH q | ΔR² val | ΔR² holdout |
|---|---|---:|---:|---:|---:|---:|---:|
| ma_dist_gold_60 | trend | 0.967 | 0.0695 | -4.11 | 0.0020 | -0.0492 | -0.0247 |
| ma_dist_gold_120 | trend | 0.983 | 0.0659 | -3.90 | 0.0024 | -0.0190 | -0.0573 |
| mom_gold_20 | momentum | 0.940 | 0.0365 | -3.44 | 0.0095 | -0.0017 | -0.0084 |
| ma_dist_gold_252 | trend | 0.992 | 0.0480 | -2.99 | 0.0228 | +0.0481 | -0.0411 |
| ma_dist_gold_20 | trend | 0.913 | 0.0202 | -2.90 | 0.0228 | +0.0070 | +0.0181 |
| mom_gold_60 | momentum | 0.977 | 0.0407 | -2.97 | 0.0228 | +0.0068 | -0.0216 |
| rel_us_gold_20 | relative_strength | 0.936 | 0.0328 | +2.91 | 0.0228 | -0.0500 | -0.0395 |
| eff_sp500_60 | trend_efficiency | 0.949 | 0.0223 | -3.06 | 0.0228 | -0.1504 | +0.0016 |
| mom_gold_10 | momentum | 0.890 | 0.0134 | -2.49 | 0.0633 | +0.0053 | +0.0177 |
| dd_gold_60 | drawdown | 0.971 | 0.0226 | -2.50 | 0.0633 | -0.0186 | -0.0266 |
| eff_nasdaq_60 | trend_efficiency | 0.951 | 0.0116 | -2.40 | 0.0732 | -0.0671 | +0.0068 |
| rel_us_gold_10 | relative_strength | 0.876 | 0.0164 | +2.20 | 0.1142 | -0.0249 | -0.0061 |
| vol_sp500_60 | volatility | 0.999 | 0.0213 | +2.16 | 0.1152 | -0.0495 | -0.0012 |
| vol_nasdaq_60 | volatility | 0.998 | 0.0196 | +2.13 | 0.1152 | -0.0575 | -0.0013 |
| dd_gold_20 | drawdown | 0.929 | 0.0092 | -1.91 | 0.1827 | +0.0015 | +0.0067 |
| mom_gold_5 | momentum | 0.791 | 0.0041 | -1.81 | 0.2159 | +0.0057 | +0.0156 |
| vol_sp500_120 | volatility | 0.999 | 0.0134 | +1.71 | 0.2505 | -0.0029 | +0.0113 |
| vol_nasdaq_120 | volatility | 0.999 | 0.0113 | +1.61 | 0.2505 | -0.0059 | +0.0075 |

## fwd_us_minus_gold_20

| factor | family | AR1 | partial R² dev | cond NW t | BH q | ΔR² val | ΔR² holdout |
|---|---|---:|---:|---:|---:|---:|---:|
| dispersion_252 | dispersion | 0.997 | 0.0268 | -3.03 | 0.1155 | -0.0001 | +0.0061 |
| chg_vix_1 | vix | -0.143 | 0.0018 | +2.73 | 0.1512 | -0.0060 | +0.0006 |
| real10_z252 | real_yield | 0.988 | 0.0254 | -2.55 | 0.1573 | +0.0286 | -0.1467 |
| vol_shanghai_60 | volatility | 0.998 | 0.0303 | -2.48 | 0.1573 | -0.0430 | -0.0013 |
| dispersion_10 | dispersion | 0.822 | 0.0059 | -2.08 | 0.1727 | +0.0069 | -0.0103 |
| rel_us_gold_20 | relative_strength | 0.936 | 0.0144 | -2.26 | 0.1727 | -0.0017 | -0.0317 |
| dd_csi300_252 | drawdown | 0.996 | 0.0281 | +2.10 | 0.1727 | -0.0310 | +0.0112 |
| dd_shanghai_252 | drawdown | 0.997 | 0.0307 | +2.17 | 0.1727 | -0.0349 | +0.0038 |
| downvol_shanghai_60 | downside_vol | 0.996 | 0.0235 | -2.12 | 0.1727 | -0.0393 | -0.0005 |
| downvol_shanghai_120 | downside_vol | 0.999 | 0.0312 | -2.23 | 0.1727 | -0.0469 | +0.0145 |
| eff_sp500_60 | trend_efficiency | 0.949 | 0.0111 | +2.06 | 0.1727 | -0.0638 | -0.0010 |
| dd_csi300_120 | drawdown | 0.992 | 0.0256 | +2.00 | 0.1784 | -0.0080 | +0.0100 |
| dd_shanghai_120 | drawdown | 0.992 | 0.0258 | +1.97 | 0.1784 | -0.0098 | +0.0094 |
| vol_shanghai_10 | volatility | 0.961 | 0.0123 | -1.93 | 0.1819 | +0.0180 | -0.0017 |
| eff_sp500_20 | trend_efficiency | 0.847 | 0.0053 | +1.85 | 0.1924 | -0.0072 | +0.0032 |
| downvol_csi300_60 | downside_vol | 0.996 | 0.0186 | -1.87 | 0.1924 | -0.0189 | +0.0041 |
| downvol_shanghai_20 | downside_vol | 0.979 | 0.0132 | -1.81 | 0.1980 | +0.0320 | -0.0122 |
| chg_vix_5 | vix | 0.722 | 0.0033 | +1.76 | 0.2098 | -0.0252 | +0.0000 |

## Interpretation rule

A candidate is strong only when it adds conditional explanatory power after current strategy weights are controlled, survives development multiple-testing correction, improves validation OOS R², and does not collapse in holdout. Raw persistent level series such as the 10Y real-yield level are diagnostic only and are not directly promotable.
