# Cloud sync performance — build 238

Two focused changes preserve the existing merge/ownership behavior:

- API decoders reuse successfully parsed timestamps inside each decoder, capped at 8192 distinct strings. There is no shared process cache and no date-format change.
- A known authenticated cloud head can use the existing lightweight check after quote-only updates. The durable baseline must still match its acknowledged signature, user content must be unchanged, and no pending upload may exist. This path never advances the acknowledged signature for unsent quotes. A changed cloud head or manual edit still runs the full guarded reconciliation/upload.

A real backup was decoded read-only with optimized Swift builds on the local Mac: 27265 date strings, 1599 unique strings, 2.866 seconds before and 0.227 seconds after. Sorted JSON encoding of the decoded payloads was byte-for-byte identical. This measures decoding, not total phone sync time. Private records remain outside Git. See `performance.json`.

Validation: `python3 scripts/test_api_date_parser.py` passed UTC, explicit offset, Shanghai local dates, fractional seconds, repeats, invalid dates and cache overflow. Focused native cloud checks passed 37/37, including no full transfer for quote-only refreshes, unchanged acknowledged baseline, and a subsequent manual quantity edit uploading normally. Native Mac Release, iOS simulator Release and the localization audit passed. See `cloud-core.json`.

TestFlight publication receipts will be recorded after Apple verification.
