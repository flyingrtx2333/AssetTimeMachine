# Spike 033 - Sleeve-Aware Vol Router

Goal: improve on the current one-way volatility-managed champion by changing
what gets scaled when the offensive engine is hotter.

Hypothesis:
- The current champion scales the whole routed target.
- A better structure may keep the current defensive engine as a core sleeve and
  scale only the offensive breadth sleeve, or redeploy clipped offensive budget
  back to the current engine instead of cash.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `baseline_one_way` | 13.53% | 9.87% | 9.53% | 1.3381 |
| `scale_breadth_sleeve_only` | 13.91% | 10.19% | 9.87% | 1.3282 |
| `core_plus_scaled_extra` | 15.69% | 13.05% | 11.35% | 1.3013 |

Conclusion:

Sleeve-aware routing raised returns, but volatility and drawdown rose with it.
The current whole-route one-way volatility scale remains the better Sharpe
tradeoff.
