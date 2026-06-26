# Spike 042 - Confirmed Acceleration Satellite

Goal: improve the promising extra-equity satellite by changing entry logic, not
just tuning allocation sizes.

Logic tested:
- Use only idle cash.
- Add Dow/Shenzhen/ChiNext exposure only after same-market confirmation.
- Require acceleration and controlled volatility.
- Suppress China exposure during bubble-rollover states.
- Keep no leverage, no shorting, no BTC.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `risk_clean_confirmed_accel_compression_no_weak_months_cap25_per10_top2` | 14.44% | 10.56% | 9.84% | 1.3771 |

Conclusion:

This is the best high-return/high-Sharpe direction found in this round, but it
still does not cross 1.4. The remaining weak point is still the 2015-05 to
2015-09 drawdown window. Do not promote yet.
