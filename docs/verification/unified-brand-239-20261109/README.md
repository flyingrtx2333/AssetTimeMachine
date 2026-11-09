# Unified in-app brand — build 239

The application icon had been updated to white and gold, but the separate brand_logo image was still black and gold. It is used by the native welcome screen, native sharing view, iOS backtest poster and iOS trend video. The native toolbar also still drew a generic system hourglass.

The shared brand resource now copies the approved 256px AppIcon artwork byte for byte. Existing dimensions and layout constraints remain unchanged. The native toolbar loads that same resource as an original-color image, with the existing system symbol retained only as a missing-resource fallback.

Native Release, iOS simulator Release and localization passed. The compiled native bundle successfully decoded the 256px non-template brand image, and its extracted artwork was visually verified as white and gold. Source-file equality to the approved artwork is recorded in asset-verification.json; exact pixel identity after AppKit color conversion is not claimed. The cloud/cache runtime code and its existing 42 checks are unchanged from d2176dc, so unrelated sync tests were not repeated.

Native installation and TestFlight 1.15 (239) publication receipts will follow after verification.
