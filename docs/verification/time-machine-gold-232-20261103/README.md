# Time Machine gold equivalent · 1.14 (232)

Final app source: `9e4148b299fe212d2a1f3eaf0ccc5bcb67b10528`.

## Corrected behavior

The iPhone main chart previously plotted `gold_cny` market-price returns on its secondary axis, while its selected-day popup showed the existing gold-equivalent quantity. The line and its displayed amount described different measurements.

The chart now plots `TimeMachineTrendPoint.goldEquivalent`: main assets divided by that snapshot’s CNY-per-gram gold anchor. Main assets are used before liabilities; this is equivalent purchasing power, not the amount of gold held. The dedicated secondary axis and popup use grams (`g`), with a distinct blue dashed line. The currency axis retains actual CNY values and now distinguishes nearby ticks such as 9.5万, 10万 and 10.5万.

The boxed Gold/Nasdaq/more selector is removed. A single Gold toggle follows the liability-gap legend in the same row. Turning it off removes the quantity curve and g axis. Privacy mode masks gram values, the secondary-axis numbers, popup values and accessibility values. Missing/invalid quotes split the line rather than becoming zero; an entirely unavailable gold series has a concise localized status. Sampling remains bounded to 180 gold observations and retains gold-quantity extrema independently of asset extrema.

The independent native Mac implementation already computes main-assets/gold-anchor grams and was not changed. Persisted models, cloud APIs, accounting calculations, strategy engines and the recorded anchor fields were retained. The Records header fix from 231 is included.

## Verification

- `scripts/test_time_machine_gold_trend.py` passed using the actual projection conversion, chart observation preparation and scale mapping. With main assets 100,000 and quotes 500→1,000, gold quantity is 200→100 grams. Higher assets at a fixed quote, unchanged quantity when both double, liability independence, zero, invalid quotes, split segments, 10,000-row bounded sampling and quantity extrema were checked. No strategy regression was expanded.
- The first iPhone Debug build passed. Visual review then identified a duplicated green series color and repeated rounded currency ticks; the final display-only changes passed a second Debug build. The release helper reuses that completed final check with `--skip-debug-build`.
- Localization audit passed: 1,553 keys, 763 direct calls, 1,078 Chinese source literals. The unavailable-gold status has English, Simplified Chinese and Traditional Chinese translations.
- Screenshots show the actual full Time Machine page, not an HTML concept or a mocked chart. A dedicated iPhone 17 Pro Max / iOS 26.5 simulator uses five synthetic 100,000-CNY snapshots. The existing app market-anchor refresh can populate or refresh quotes with public market data, so the screenshots are not claimed as a frozen 500→1,000 price experiment; that deterministic inverse-price case is verified separately by the source-based check. No signed-in account or private user export was used.
- Each saved capture waited eight seconds after launch. [Before 231](before-light.png), final [gold enabled light](after-gold-light.png) / [dark](after-gold-dark.png), [gold disabled](after-gold-off.png) and [privacy](after-private.png) are 1320×2868 pixels. The final images show the compact four-item legend, g values and axis, distinct curve color, disabled state and masked values. No physical-touch or back-navigation acceptance is claimed.

TestFlight **1.14 (232)** is `VALID` and `IN_BETA_TESTING` in internal group `flyingrtx`. The verified Apple upload and processed build share ID `259efe0c-d44c-4739-b9bc-5b2f8d75213b`. Apple and the local IPA both contain **17,747,451 bytes**, MD5 **`bbc0077b8263fdc4fc711c90703e0995`**. Three localized release notes passed readback. The strict archive signature, archive/export UUID match and all copied artifact SHA256 checks passed. Artifacts are retained in Mac mini’s persistent Application Support release directory. The dedicated simulator used for both follow-up fixes and the completed release agent were removed. No App Store release or external beta review was submitted. Physical-device acceptance remains pending.
