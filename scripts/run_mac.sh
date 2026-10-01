#!/bin/bash
# Build and launch the Mac app with development signing when available.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${MAC_SIGNING:-auto}" != "adhoc" ]] && security find-identity -v -p codesigning | grep -q 'Apple Development:'; then
  MAC_BUILD_DIR="$REPO_ROOT/build/mac-signed-release"
  MAC_APP_DEST="$REPO_ROOT/build/AssetTimeMachine-Mac-Signed.app"
  SIGNING_ARGS=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  echo 'Using Apple Development signing for Mac cloud login.'
else
  MAC_BUILD_DIR="$REPO_ROOT/build/mac-release"
  MAC_APP_DEST="$REPO_ROOT/build/AssetTimeMachine-Mac.app"
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
  echo 'Using local preview signing; Apple login and cloud sync are unavailable.'
fi
mkdir -p "$MAC_BUILD_DIR"
xcodebuild -project "$REPO_ROOT/AssetTimeMachine.xcodeproj" \
  -scheme AssetTimeMachine -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$MAC_BUILD_DIR" "${SIGNING_ARGS[@]}" build \
  > "$REPO_ROOT/build/mac-build.log" 2>&1 || {
    tail -80 "$REPO_ROOT/build/mac-build.log"
    exit 1
  }
MAC_APP="$MAC_BUILD_DIR/Build/Products/Release-maccatalyst/AssetTimeMachine.app"
if [[ "$MAC_APP_DEST" == "$REPO_ROOT/build/AssetTimeMachine-Mac.app" ]]; then
  codesign --force --deep --sign - "$MAC_APP"
fi
# Verify the new build before replacing the current app; retain one rollback.
python3 "$REPO_ROOT/scripts/mac_build_artifacts.py" install "$MAC_APP" "$(basename "$MAC_APP_DEST")"
MAC_APP="$MAC_APP_DEST"
codesign --verify --deep --strict "$MAC_APP"
python3 "$REPO_ROOT/scripts/mac_build_artifacts.py" clean --apply --keep-app "$(basename "$MAC_APP")"
if [[ "${MAC_BUILD_ONLY:-0}" != "1" ]]; then
  open "$MAC_APP" --args "$@"
fi
printf 'Mac app: %s\n' "$MAC_APP"
