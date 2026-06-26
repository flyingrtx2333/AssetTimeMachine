# Spike 078 - Stress Tilted Quality Basket

Goal: improve the spike 074 annual quality/core basket by adding a stress-state
overlay.  The base basket stays long-only and unlevered; when `CORE` or the
quality satellite sleeve is under stress, part of that risk exposure is
temporarily redeployed into `OSTIX` and `IAU`.

Method:
- Review every 63 or 126 sessions.
- Detect stress through 126-session drawdown plus 63-session negative momentum.
- Cut a portion of `CORE` and/or quality satellites during stress.
- Redeploy the cut exposure into `OSTIX` and `IAU`.
- 1% fee and 0.05% slippage on external assets.
- No leverage, no shorting, no BTC.

Best full-history Sharpe:

| Base | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe | Last-10Y Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `max_sharpe` stress tilt | 9.91% | 13.06% | 5.69% | 1.6377 | 1.4944 | 1.5543 |

Best return/Sharpe balance:

| Base | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe | Last-10Y Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `middle` stress tilt | 11.43% | 15.44% | 6.65% | 1.6096 | 1.4224 | 1.5302 |
| `annual12` stress tilt | 11.78% | 14.64% | 6.93% | 1.5909 | 1.4108 | 1.5007 |
| `annual1230` stress tilt | 12.04% | 18.58% | 7.20% | 1.5655 | 1.4408 | 1.5447 |

Conclusion:

Promising and stronger than spike 074.

The stress overlay improves the high-Sharpe frontier:

- prior best: 10.22% annualized / 1.6070 Sharpe;
- new best: 9.91% annualized / 1.6377 Sharpe;
- best balanced candidate: 11.43% annualized / 1.6096 Sharpe.

It still does not achieve 12%+ annualized with 1.6+ Sharpe, but it gets closer
than previous candidates while keeping the logic product-readable.
