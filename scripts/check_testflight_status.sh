#!/usr/bin/env bash
set -euo pipefail

ASC_ENV="${ASC_ENV:-$HOME/.appstoreconnect/assettimemachine.env}"
STATUS_ATTEMPTS="${STATUS_ATTEMPTS:-12}"
STATUS_SLEEP_SECONDS="${STATUS_SLEEP_SECONDS:-10}"
STATUS_REQUEST_TIMEOUT="${STATUS_REQUEST_TIMEOUT:-25}"

if [[ $# -ne 1 ]]; then
    echo "Usage: scripts/check_testflight_status.sh <delivery-uuid>" >&2
    exit 64
fi

DELIVERY_ID="$1"
if [[ ! "$DELIVERY_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "Invalid delivery UUID" >&2
    exit 65
fi
if [[ ! -f "$ASC_ENV" ]]; then
    echo "App Store Connect env file not found: $ASC_ENV" >&2
    exit 66
fi

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

for attempt in $(seq 1 "$STATUS_ATTEMPTS"); do
    echo "STATUS_ATTEMPT=$attempt"
    set +e
    OUTPUT="$(python3 - "$DELIVERY_ID" "$STATUS_REQUEST_TIMEOUT" <<'PY'
import os
import subprocess
import sys

delivery_id = sys.argv[1]
timeout_seconds = float(sys.argv[2])
command = [
    "xcrun", "altool", "--build-status",
    "--delivery-id", delivery_id,
    "--apiKey", os.environ["ASC_KEY_ID"],
    "--apiIssuer", os.environ["ASC_ISSUER_ID"],
]
try:
    result = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout_seconds,
        check=False,
    )
    print(result.stdout, end="")
    raise SystemExit(result.returncode)
except subprocess.TimeoutExpired as error:
    output = error.stdout or ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    print(output, end="")
    print("STATUS_REQUEST_TIMEOUT")
    raise SystemExit(124)
PY
)"
    REQUEST_STATUS=$?
    set -e
    printf '%s\n' "$OUTPUT"

    if grep -q "BUILD-STATUS: VALID" <<<"$OUTPUT"; then
        echo "ASC_VALID"
        exit 0
    fi
    if grep -Eq "BUILD-STATUS: (FAILED|INVALID)" <<<"$OUTPUT"; then
        echo "ASC_FAILED"
        exit 2
    fi
    if [[ "$REQUEST_STATUS" -ne 0 && "$REQUEST_STATUS" -ne 124 ]]; then
        echo "STATUS_REQUEST_FAILED=$REQUEST_STATUS" >&2
    fi
    if [[ "$attempt" -lt "$STATUS_ATTEMPTS" ]]; then
        sleep "$STATUS_SLEEP_SECONDS"
    fi
done

echo "ASC_STATUS_PENDING"
exit 3
