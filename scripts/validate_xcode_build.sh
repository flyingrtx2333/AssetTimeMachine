#!/bin/bash
# Disposable Release validation: generated products are removed even on failure.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-ios}"
case "$TARGET" in
  ios)
    PROJECT="$PROJECT_ROOT/AssetTimeMachine.xcodeproj"
    SCHEME=AssetTimeMachine
    DESTINATION='generic/platform=iOS Simulator'
    ;;
  native)
    PROJECT="$PROJECT_ROOT/AssetTimeMachineNativeMac/AssetTimeMachineNativeMac.xcodeproj"
    SCHEME=AssetTimeMachineNativeMac
    DESTINATION='platform=macOS'
    ;;
  catalyst)
    PROJECT="$PROJECT_ROOT/AssetTimeMachine.xcodeproj"
    SCHEME=AssetTimeMachine
    DESTINATION='platform=macOS,variant=Mac Catalyst'
    ;;
  *) echo 'Usage: scripts/validate_xcode_build.sh ios|native|catalyst' >&2; exit 2 ;;
esac
if [[ -L "$PROJECT_ROOT/build" ]]; then
  echo 'The build directory must not be a symlink.' >&2
  exit 1
fi
mkdir -p "$PROJECT_ROOT/build"
DERIVED="$(mktemp -d "$PROJECT_ROOT/build/.validation-$TARGET.XXXXXX")"
LOG="$PROJECT_ROOT/build/validation-$TARGET.log"
BUILD_PID=''
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$BUILD_PID" ]] && kill -0 "$BUILD_PID" 2>/dev/null; then
    kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
  fi
  rm -rf -- "$DERIVED"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build > "$LOG" 2>&1 &
BUILD_PID=$!
if ! wait "$BUILD_PID"; then
  tail -80 "$LOG"
  exit 1
fi
BUILD_PID=''
printf 'Release %s validation passed; temporary build products will be removed. Log: %s\n' "$TARGET" "$LOG"
