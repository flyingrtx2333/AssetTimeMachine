#!/usr/bin/env bash
set -euo pipefail

PROJECT="AssetTimeMachine.xcodeproj"
SCHEME="AssetTimeMachine"
TEAM_ID="8BPSC5L74V"
ASC_ENV="${ASC_ENV:-$HOME/.appstoreconnect/assettimemachine.env}"
DESTINATION_SIMULATOR="${DESTINATION_SIMULATOR:-platform=iOS Simulator,name=iPhone 17 Pro Max}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-40}"
POLL_SLEEP_SECONDS="${POLL_SLEEP_SECONDS:-30}"

RUN_DEBUG_BUILD=1
BUMP_BUILD=1
COMMIT_MESSAGE=""
TARGET_MARKETING_VERSION=""

usage() {
    cat <<'USAGE'
Usage:
  scripts/release_testflight.sh [options]

Options:
  --version "1.0.6"       Set MARKETING_VERSION before building.
  --commit-message "msg"  Commit current changes plus build bump before archiving.
  --skip-debug-build      Skip simulator Debug build preflight.
  --no-bump               Do not increment CURRENT_PROJECT_VERSION.
  -h, --help              Show this help.

Environment:
  ASC_ENV                 App Store Connect env file path.
  DESTINATION_SIMULATOR   xcodebuild simulator destination.
  POLL_ATTEMPTS           App Store Connect polling attempts, default 40.
  POLL_SLEEP_SECONDS      Seconds between polling attempts, default 30.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            TARGET_MARKETING_VERSION="${2:-}"
            if [[ -z "$TARGET_MARKETING_VERSION" ]]; then
                echo "Missing value for --version" >&2
                exit 64
            fi
            shift 2
            ;;
        --commit-message)
            COMMIT_MESSAGE="${2:-}"
            if [[ -z "$COMMIT_MESSAGE" ]]; then
                echo "Missing value for --commit-message" >&2
                exit 64
            fi
            shift 2
            ;;
        --skip-debug-build)
            RUN_DEBUG_BUILD=0
            shift
            ;;
        --no-bump)
            BUMP_BUILD=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

cd "$(dirname "$0")/.."

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "Required file not found: $1" >&2
        exit 66
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 69
    fi
}

require_command python3
require_command xcodebuild
require_command xcrun
require_file "$PROJECT/project.pbxproj"
require_file "$ASC_ENV"

set -a
# shellcheck disable=SC1090
source "$ASC_ENV"
set +a

for name in ASC_KEY_ID ASC_ISSUER_ID; do
    if [[ -z "${!name:-}" ]]; then
        echo "Missing $name in $ASC_ENV" >&2
        exit 78
    fi
done

read_versions() {
    python3 - <<'PY'
from pathlib import Path
import re
text = Path("AssetTimeMachine.xcodeproj/project.pbxproj").read_text()
builds = sorted(set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text)))
versions = sorted(set(re.findall(r"MARKETING_VERSION = ([^;]+);", text)))
if len(builds) != 1 or len(versions) != 1:
    raise SystemExit(f"Unexpected project versions: builds={builds}, versions={versions}")
print(builds[0])
print(versions[0])
PY
}

VERSION_OUTPUT="$(read_versions)"
CURRENT_BUILD="$(printf '%s\n' "$VERSION_OUTPUT" | sed -n '1p')"
MARKETING_VERSION="$(printf '%s\n' "$VERSION_OUTPUT" | sed -n '2p')"

if [[ -n "$TARGET_MARKETING_VERSION" ]]; then
    if ! [[ "$TARGET_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
        echo "Invalid version: $TARGET_MARKETING_VERSION" >&2
        echo "Expected something like 1.0.6" >&2
        exit 65
    fi
    log "Setting marketing version $MARKETING_VERSION -> $TARGET_MARKETING_VERSION"
    python3 - "$MARKETING_VERSION" "$TARGET_MARKETING_VERSION" <<'PY'
from pathlib import Path
import sys
old, new = sys.argv[1:3]
path = Path("AssetTimeMachine.xcodeproj/project.pbxproj")
text = path.read_text()
needle = f"MARKETING_VERSION = {old};"
replacement = f"MARKETING_VERSION = {new};"
count = text.count(needle)
if count == 0:
    raise SystemExit(f"Could not find {needle}")
path.write_text(text.replace(needle, replacement))
print(f"Updated {count} marketing version setting(s)")
PY
    MARKETING_VERSION="$TARGET_MARKETING_VERSION"
fi

if [[ "$BUMP_BUILD" -eq 1 ]]; then
    if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
        echo "CURRENT_PROJECT_VERSION is not an integer: $CURRENT_BUILD" >&2
        exit 65
    fi
    NEXT_BUILD="$((CURRENT_BUILD + 1))"
    log "Bumping build $CURRENT_BUILD -> $NEXT_BUILD"
    python3 - "$CURRENT_BUILD" "$NEXT_BUILD" <<'PY'
from pathlib import Path
import sys
old, new = sys.argv[1:3]
path = Path("AssetTimeMachine.xcodeproj/project.pbxproj")
text = path.read_text()
needle = f"CURRENT_PROJECT_VERSION = {old};"
replacement = f"CURRENT_PROJECT_VERSION = {new};"
count = text.count(needle)
if count == 0:
    raise SystemExit(f"Could not find {needle}")
path.write_text(text.replace(needle, replacement))
print(f"Updated {count} build setting(s)")
PY
    CURRENT_BUILD="$NEXT_BUILD"
else
    log "Using existing build $CURRENT_BUILD"
fi

BUILD_DIR="$PWD/build/TestFlight-$MARKETING_VERSION-$CURRENT_BUILD"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT="$BUILD_DIR/export"
IPA="$EXPORT/$SCHEME.ipa"
ARCHIVE_LOG="$BUILD_DIR/archive.log"
EXPORT_LOG="$BUILD_DIR/export.log"
UPLOAD_LOG="$BUILD_DIR/upload.log"
STATUS_LOG="$BUILD_DIR/build-status.log"

log "Version $MARKETING_VERSION ($CURRENT_BUILD)"
log "Build dir: $BUILD_DIR"

log "Running git diff --check"
git diff --check

if [[ "$RUN_DEBUG_BUILD" -eq 1 ]]; then
    log "Running Debug build"
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "$DESTINATION_SIMULATOR" \
        build
fi

if [[ -n "$COMMIT_MESSAGE" ]]; then
    log "Committing release changes"
    git add -A
    git commit -m "$COMMIT_MESSAGE"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT"

log "Archiving Release build"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    > "$ARCHIVE_LOG" 2>&1 || { tail -n 180 "$ARCHIVE_LOG"; exit 1; }
tail -n 45 "$ARCHIVE_LOG"

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

log "Exporting IPA"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates \
    > "$EXPORT_LOG" 2>&1 || { tail -n 180 "$EXPORT_LOG"; exit 1; }

if [[ ! -f "$IPA" ]]; then
    IPA="$(find "$EXPORT" -name '*.ipa' -print -quit)"
fi
if [[ -z "${IPA:-}" || ! -f "$IPA" ]]; then
    echo "IPA not found under $EXPORT" >&2
    exit 70
fi
ls -lh "$IPA"

log "Uploading to App Store Connect"
xcrun altool --upload-app \
    --type ios \
    --file "$IPA" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    > "$UPLOAD_LOG" 2>&1 || { tail -n 180 "$UPLOAD_LOG"; exit 1; }
tail -n 120 "$UPLOAD_LOG"

DELIVERY_ID="$(grep -Eo '[0-9a-fA-F-]{36}' "$UPLOAD_LOG" | tail -n 1)"
if [[ -z "$DELIVERY_ID" ]]; then
    echo "Delivery UUID not found in upload log: $UPLOAD_LOG" >&2
    exit 70
fi
echo "DELIVERY_ID=$DELIVERY_ID" > "$BUILD_DIR/delivery-id.txt"

log "Polling App Store Connect build status"
: > "$STATUS_LOG"
for attempt in $(seq 1 "$POLL_ATTEMPTS"); do
    echo "--- attempt $attempt $(date) ---" | tee -a "$STATUS_LOG"
    xcrun altool --build-status \
        --delivery-id "$DELIVERY_ID" \
        --apiKey "$ASC_KEY_ID" \
        --apiIssuer "$ASC_ISSUER_ID" \
        2>&1 | tee -a "$STATUS_LOG"

    if grep -q "BUILD-STATUS: VALID" "$STATUS_LOG"; then
        echo "ASC_VALID" | tee -a "$STATUS_LOG"
        cat <<SUMMARY

TestFlight upload complete.
Version: $MARKETING_VERSION ($CURRENT_BUILD)
Delivery UUID: $DELIVERY_ID
Status: BUILD-STATUS: VALID
Build dir: $BUILD_DIR
SUMMARY
        exit 0
    fi
    if grep -Eq "BUILD-STATUS: (FAILED|INVALID)" "$STATUS_LOG"; then
        echo "ASC_FAILED" | tee -a "$STATUS_LOG"
        exit 2
    fi
    sleep "$POLL_SLEEP_SECONDS"
done

echo "ASC_TIMEOUT" | tee -a "$STATUS_LOG"
exit 3
