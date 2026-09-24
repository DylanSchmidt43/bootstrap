#!/bin/bash
# Public bootstrap for the self-service Windows installer.
#
# This is the ONLY file meant to be read directly on GitHub - the real
# installer lives in an AES-encrypted archive in the same repo and is never
# readable without a passphrase issued per-request by the bot's server (which
# also reserves the caller's point for this install). See
# windowsInstallerPointPlan.md for the full design.
#
# Usage (the bot generates this exact command for the user):
#
#   curl -fsSL <REPO_BASE_URL>/bootstrap.sh | \
#     REPO_BASE_URL='...' START_ENDPOINT='...' API_ENDPOINT='...' STATUS_ENDPOINT='...' \
#     API_TOKEN='<installer_key>' \
#     bash -s -- <windows_version> <request_token>

set -u
set -o pipefail
umask 077

WIN_VERSION="${1:-}"
REQUEST_TOKEN="${2:-}"

for VAR_NAME in REPO_BASE_URL START_ENDPOINT API_ENDPOINT STATUS_ENDPOINT API_TOKEN; do
    if [ -z "${!VAR_NAME:-}" ]; then
        echo "FATAL: $VAR_NAME must be set (this command should come from the bot, not be edited by hand)." >&2
        exit 90
    fi
done
if [ -z "$WIN_VERSION" ] || [ -z "$REQUEST_TOKEN" ]; then
    echo "Usage: bash -s -- <windows_version> <request_token>" >&2
    exit 90
fi

command -v curl >/dev/null 2>&1 || { echo "FATAL: curl is required." >&2; exit 91; }
command -v openssl >/dev/null 2>&1 || { echo "FATAL: openssl is required." >&2; exit 91; }
command -v tar >/dev/null 2>&1 || { echo "FATAL: tar is required." >&2; exit 91; }

echo "=== Requesting install authorization (this reserves 1 point) ==="

START_RESPONSE=$(
    curl \
        --ipv4 \
        --silent \
        --show-error \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST \
        "$START_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_TOKEN" \
        --data "{\"request_token\":\"$REQUEST_TOKEN\"}"
)
CURL_STATUS=$?
if [ $CURL_STATUS -ne 0 ]; then
    echo "FATAL: could not reach $START_ENDPOINT (curl exit $CURL_STATUS)." >&2
    exit 92
fi

extract_json_field()
{
    local FIELD="$1"
    local JSON="$2"
    if command -v python3 >/dev/null 2>&1; then
        JSON_INPUT="$JSON" python3 -c "
import json, os, sys
try:
    data = json.loads(os.environ.get('JSON_INPUT', ''))
except Exception:
    sys.exit(1)
value = data.get('$FIELD')
if value is None:
    sys.exit(1)
print(value)
"
        return
    fi
    printf '%s' "$JSON" | sed -n "s/.*\"$FIELD\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

AES_PASSPHRASE=$(extract_json_field "aes_passphrase" "$START_RESPONSE")
if [ -z "$AES_PASSPHRASE" ]; then
    STATUS_MSG=$(extract_json_field "message" "$START_RESPONSE")
    echo "FATAL: install not authorized: ${STATUS_MSG:-no passphrase returned}. No point was charged; nothing on this machine was touched." >&2
    exit 93
fi

echo "=== Authorized. Downloading installer package ==="

WORKDIR=$(mktemp -d /tmp/win-installer.XXXXXX)
cleanup()
{
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

ENCRYPTED_PATH="$WORKDIR/installer-selfservice.tar.gz.enc"
if ! curl \
        --fail \
        --silent \
        --show-error \
        --connect-timeout 10 \
        --max-time 120 \
        -o "$ENCRYPTED_PATH" \
        "$REPO_BASE_URL/installer-selfservice.tar.gz.enc"
then
    echo "FATAL: failed to download installer package from $REPO_BASE_URL." >&2
    exit 94
fi

echo "=== Decrypting and extracting (in-memory passphrase, never written to disk) ==="

if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:$AES_PASSPHRASE" -in "$ENCRYPTED_PATH" \
        | tar xz -C "$WORKDIR"
then
    echo "FATAL: decryption or extraction failed. Wrong passphrase, corrupted download, or tampered package." >&2
    exit 95
fi
rm -f "$ENCRYPTED_PATH"
unset AES_PASSPHRASE

if [ ! -f "$WORKDIR/installVPSWindows.sh" ]; then
    echo "FATAL: extracted package is missing installVPSWindows.sh." >&2
    exit 96
fi

echo "=== Starting Windows install ==="
chmod +x "$WORKDIR/installVPSWindows.sh"
cd "$WORKDIR"
bash installVPSWindows.sh "$WIN_VERSION" "$REQUEST_TOKEN"
INSTALL_EXIT=$?

exit "$INSTALL_EXIT"
