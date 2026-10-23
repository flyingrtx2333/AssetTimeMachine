# KVO iOS integration

Adds the KVO price–volume portfolio to the experimental strategy catalog, local backtests and latest-completed-period allocation advice. The default recommended strategy remains unchanged. Release baseline is the already shipped TestFlight 1.14 (206), commit 20076b6.

The existing KE25 parent, source clock, independent K/E state, fixed 75/25 target mixture, 4% rebalance band and original shared settlement engine are reused. Only the two China-equity E entry permissions gain the frozen KVO34/55 + EMA13 histogram condition. The port retains the original Tulip-reference episode seeds, prior-native-j−1 quantity, strict signs, independent finite-precision Decimal checks, missing-quantity price-rule fallback and fixed own-entry-low exit. No frozen historical schedule is used in production.

Public-history volumes must be finite, nonnegative exactly representable integers within binary64's exact-integer range before conversion into decimal UInt64 tokens. No volume is invented, interpolated or forward filled. Numeric/integrity failures reject calculation; missing/zero quantities retain the original UNKNOWN behavior. Quantity physical units, historical publication/PIT and future investment performance remain uncertified, as in the research record.

The test-only public-data fixtures retain the original market frame, native OHLC, vendor quantity records and all5735 expected targets from `cn-vendor-kvo-episode-range-fixed-quarter-method-audit-2026-10-22`. They are copied only into the test bundle. The numerical kernel is ported from that study; research disk-witness and report-template IO is omitted. Tests compare every target key/Float64 bit, original full-account metrics/fills, a physically cropped native/quantity prefix, and the unchanged KE25 control. A separate production-API response exercises daily advice and the App's backtest entry.

Expected original-vintage KVO full account: CAGR0.06507971966997173, AppRf0Sharpe1.2745814030615343, DD0.07557506265754006,12178fills,5735states. These are historical research results, not a certification of Sharpe>=1.3. Actual newer App data and user costs can change backtest results.

Build/test/upload receipts and the exact signed source commit are recorded separately after release. The canonical research checkout and its unfinished unrelated UI/localization changes are preserved.
