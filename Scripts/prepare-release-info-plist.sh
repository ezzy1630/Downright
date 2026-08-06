#!/bin/bash
# Prepare the production Info.plist for a release build.
#
# The committed Config/Downright-Info.plist carries a placeholder public key
# (the private key must never live in the repository).  This script substitutes
# the real key — supplied via the SPARKLE_ED25519_PUBLIC_KEY environment
# variable (the GitHub release environment secret) — into Config/Release-Info.plist.
#
# The release workflow runs this before xcodebuild and passes
# INFOPLIST_FILE=Config/Release-Info.plist, so the placeholder never ships.
#
# The injection uses PlistBuddy, not sed: Ed25519 public keys are base64 and
# routinely contain '/' and '&', which would corrupt a plain-text substitution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KEY="${SPARKLE_ED25519_PUBLIC_KEY:-}"
[ -n "$KEY" ] || { echo "SPARKLE_ED25519_PUBLIC_KEY is required" >&2; exit 1; }

OUT="Config/Release-Info.plist"
# Copy the committed plist, then set the key with a plist-aware tool.
cp Config/Downright-Info.plist "$OUT"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $KEY" "$OUT"

# Prove the placeholder is gone and the file is well-formed.
if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$OUT" | grep -q "PLACEHOLDER"; then
    echo "key injection failed: placeholder still present in $OUT" >&2
    exit 1
fi
plutil -lint "$OUT" >/dev/null

# Never echo the key itself.
echo "wrote $OUT (key injected via PlistBuddy, not echoed)"
