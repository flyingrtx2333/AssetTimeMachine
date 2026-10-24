#!/bin/bash
# Build the independent native macOS target in this repository.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$PROJECT_ROOT/build/native-release"
LOG="$PROJECT_ROOT/build/native-mac-build.log"
mkdir -p "$PROJECT_ROOT/build"
NATIVE_VERSIONS="$(python3 - "$PROJECT_ROOT/AssetTimeMachine.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
    values = set(re.findall(key + r" = ([^;]+);", text))
    if len(values) != 1:
        raise SystemExit("Inconsistent app version settings")
    print(values.pop())
PY
)"
NATIVE_MARKETING_VERSION="$(printf '%s\n' "$NATIVE_VERSIONS" | sed -n '1p')"
NATIVE_BUILD_VERSION="$(printf '%s\n' "$NATIVE_VERSIONS" | sed -n '2p')"
NATIVE_SOURCE_REVISION="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)"
if ! git -C "$PROJECT_ROOT" diff --quiet; then NATIVE_SOURCE_REVISION="$NATIVE_SOURCE_REVISION-modified"; fi
xcodebuild -project "$PROJECT_ROOT/AssetTimeMachineNativeMac/AssetTimeMachineNativeMac.xcodeproj" \
  -scheme AssetTimeMachineNativeMac -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$NATIVE_MARKETING_VERSION" CURRENT_PROJECT_VERSION="$NATIVE_BUILD_VERSION" \
  build > "$LOG" 2>&1 || {
    tail -80 "$LOG"
    exit 1
  }
SOURCE="$DERIVED/Build/Products/Release/AssetTimeMachine.app"
DEST="$PROJECT_ROOT/build/AssetTimeMachine-Native.app"
STAGING="$(mktemp -d "$PROJECT_ROOT/build/.native-install.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGED_APP="$STAGING/AssetTimeMachine.app"
ditto "$SOURCE" "$STAGED_APP"
python3 - "$STAGED_APP/Contents/Info.plist" "$NATIVE_SOURCE_REVISION" <<'PY'
from pathlib import Path
import plistlib, sys
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info["ATMSourceRevision"] = sys.argv[2]
path.write_bytes(plistlib.dumps(info))
PY
PROFILE="$PROJECT_ROOT/build/AssetTimeMachine-Mac-Signed.app/Contents/embedded.provisionprofile"
if [[ ! -f "$PROFILE" && -f "$DEST/Contents/embedded.provisionprofile" ]]; then
  PROFILE="$DEST/Contents/embedded.provisionprofile"
fi
SIGNING_ID="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development:[^"]*)".*/\1/p' | head -1)"
if [[ -f "$PROFILE" && -n "$SIGNING_ID" ]]; then
  cp "$PROFILE" "$STAGED_APP/Contents/embedded.provisionprofile"
  SIGNED_ENTITLEMENTS="$STAGING/native-signed-entitlements.plist"
  python3 - "$PROJECT_ROOT/AssetTimeMachine/AssetTimeMachineMac.entitlements" "$PROFILE" "$SIGNED_ENTITLEMENTS" <<'PY'
import plistlib, subprocess, sys
from pathlib import Path
base, profile, output = map(Path, sys.argv[1:])
entitlements = plistlib.loads(base.read_bytes())
allowed = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(profile)]))["Entitlements"]
identifier = allowed["com.apple.application-identifier"]
if identifier.split(".", 1)[1] != "com.flyingrtx.AssetTimeMachine.mac":
    raise SystemExit("The native Mac provisioning profile has the wrong application identity")
entitlements["com.apple.application-identifier"] = identifier
entitlements["com.apple.developer.team-identifier"] = allowed["com.apple.developer.team-identifier"]
entitlements["keychain-access-groups"] = [identifier]
output.write_bytes(plistlib.dumps(entitlements))
PY
  codesign --force --deep --options runtime \
    --entitlements "$SIGNED_ENTITLEMENTS" \
    --sign "$SIGNING_ID" "$STAGED_APP"
  codesign --verify --deep --strict "$STAGED_APP"
  echo 'Native Mac app signed for Apple login and App Group.'
else
  if [[ -f "$DEST/Contents/embedded.provisionprofile" ]]; then
    echo 'Development signing is unavailable; the existing signed app was preserved.' >&2
    exit 1
  fi
  codesign --force --deep --sign - "$STAGED_APP"
  echo 'Native Mac preview signed locally; Apple login and App Group access require a development profile.'
fi
python3 "$PROJECT_ROOT/scripts/mac_build_artifacts.py" install "$STAGED_APP" "$(basename "$DEST")"
python3 "$PROJECT_ROOT/scripts/mac_build_artifacts.py" clean --apply
printf 'Mac app: %s\n' "$DEST"
if [[ "${MAC_BUILD_ONLY:-0}" != "1" ]]; then
  open "$DEST" --args "$@"
fi
