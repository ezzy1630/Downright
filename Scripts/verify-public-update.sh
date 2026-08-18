#!/bin/bash
# Verify the public Sparkle channel after a release deploy.
#
# Usage:
#   Scripts/verify-public-update.sh FEED_URL SHORT_VERSION BUILD RELEASE_TAG
#
# The release job already verifies the generated appcast with Sparkle's
# signing tool before publication. This post-deploy gate checks the different
# failure modes that only exist at the public boundary: Pages serving the old
# feed, malformed XML, a missing item/enclosure signature, or a release asset
# URL that does not resolve.
set -euo pipefail

FEED_URL="${1:?usage: verify-public-update.sh FEED_URL SHORT_VERSION BUILD RELEASE_TAG}"
EXPECTED_SHORT_VERSION="${2:?usage: verify-public-update.sh FEED_URL SHORT_VERSION BUILD RELEASE_TAG}"
EXPECTED_BUILD="${3:?usage: verify-public-update.sh FEED_URL SHORT_VERSION BUILD RELEASE_TAG}"
EXPECTED_RELEASE_TAG="${4:?usage: verify-public-update.sh FEED_URL SHORT_VERSION BUILD RELEASE_TAG}"
ATTEMPTS="${VERIFY_PUBLIC_UPDATE_ATTEMPTS:-30}"
DELAY_SECONDS="${VERIFY_PUBLIC_UPDATE_DELAY_SECONDS:-2}"

command -v curl >/dev/null || { echo "verify-public-update: curl is required" >&2; exit 1; }
command -v xmllint >/dev/null || { echo "verify-public-update: xmllint is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "verify-public-update: python3 is required" >&2; exit 1; }

if ! echo "$ATTEMPTS" | grep -Eq '^[1-9][0-9]*$'; then
    echo "verify-public-update: VERIFY_PUBLIC_UPDATE_ATTEMPTS must be a positive integer" >&2
    exit 1
fi
if ! echo "$DELAY_SECONDS" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
    echo "verify-public-update: VERIFY_PUBLIC_UPDATE_DELAY_SECONDS must be numeric" >&2
    exit 1
fi

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TEMP_ROOT/downright-public-update.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
FEED_FILE="$WORK_DIR/appcast.xml"
ERROR_FILE="$WORK_DIR/error.txt"

validate_feed() {
    curl -fsSL --max-time 30 --retry 2 --retry-delay 1 "$FEED_URL" -o "$FEED_FILE"
    xmllint --noout "$FEED_FILE"

    # Feed signatures are Sparkle comments appended by generate_appcast rather
    # than XML nodes. Keep both checks explicit so a valid-looking but unsigned
    # feed cannot pass this public-boundary gate.
    grep -Eq 'sparkle-signatures:' "$FEED_FILE"
    grep -Eq 'edSignature:[[:space:]]*[A-Za-z0-9+/=]+' "$FEED_FILE"

    python3 - "$FEED_FILE" "$EXPECTED_SHORT_VERSION" "$EXPECTED_BUILD" "$EXPECTED_RELEASE_TAG" <<'PY'
import sys
import urllib.parse
import xml.etree.ElementTree as ET

feed_path, expected_short, expected_build, expected_tag = sys.argv[1:]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"

def fail(message: str) -> None:
    print(f"verify-public-update: {message}", file=sys.stderr)
    raise SystemExit(1)

try:
    root = ET.parse(feed_path).getroot()
except (ET.ParseError, OSError) as error:
    fail(f"could not parse appcast: {error}")

items = root.findall("./channel/item")
if not items:
    fail("appcast has no channel item")

item = items[0]
actual_short = item.findtext(f"{{{sparkle}}}shortVersionString")
actual_build = item.findtext(f"{{{sparkle}}}version")
if actual_short != expected_short:
    fail(f"latest short version is {actual_short!r}, expected {expected_short!r}")
if actual_build != expected_build:
    fail(f"latest build is {actual_build!r}, expected {expected_build!r}")

enclosure = item.find("enclosure")
if enclosure is None:
    fail("latest item has no full-update enclosure")

url = enclosure.attrib.get("url", "")
if not url:
    fail("latest enclosure has no URL")
parsed = urllib.parse.urlparse(url)
if parsed.scheme != "https" or not parsed.netloc:
    fail("latest enclosure URL is not an HTTPS URL")
if expected_tag not in url:
    fail(f"latest enclosure does not point at release {expected_tag!r}")

try:
    length = int(enclosure.attrib.get("length", "0"))
except ValueError:
    length = 0
if length <= 0:
    fail("latest enclosure has no positive byte length")

signature = enclosure.attrib.get(f"{{{sparkle}}}edSignature", "")
if not signature:
    fail("latest enclosure has no Sparkle EdDSA signature")

# Only emit a public URL. Never echo feed signatures or updater keys into CI
# logs, even though they are not credentials.
print(url)
PY
}

for attempt in $(seq 1 "$ATTEMPTS"); do
    ENCLOSURE_URL=""
    if ENCLOSURE_URL="$(validate_feed 2>"$ERROR_FILE")" \
       && curl -fsSL -L --max-time 60 --retry 2 --retry-delay 1 -r 0-0 \
            -o /dev/null "$ENCLOSURE_URL" 2>>"$ERROR_FILE"; then
        echo "verify-public-update: public feed is current"
        echo "    version: $EXPECTED_SHORT_VERSION"
        echo "    build: $EXPECTED_BUILD"
        echo "    release: $EXPECTED_RELEASE_TAG"
        exit 0
    fi

    if [ "$attempt" -lt "$ATTEMPTS" ]; then
        sleep "$DELAY_SECONDS"
    fi
done

echo "verify-public-update: public feed did not become healthy after $ATTEMPTS attempt(s)" >&2
sed -n '1,20p' "$ERROR_FILE" >&2 || true
exit 1
