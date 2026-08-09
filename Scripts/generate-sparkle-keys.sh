#!/bin/bash
# Generate the Downright Sparkle Ed25519 key pair — run this OFFLINE, once.
#
# The private key must never be committed, pasted into chat, or left on disk.
# It exists in exactly two places after this script finishes:
#   1. your login keychain (generate_keys stores it there),
#   2. the encrypted offline backup you create below.
# The public key goes into two places: the GitHub `release` environment secret
# SPARKLE_ED25519_PUBLIC_KEY, and (via the release workflow) every production
# Info.plist as SUPublicEDKey.
#
# Usage:
#   Scripts/generate-sparkle-keys.sh [--to-file DIR]
#
# With --to-file DIR the private key is also exported to
#   DIR/downright-sparkle-ed25519.key  (chmod 600)
# so it can be copied into a password manager / encrypted vault.  The workflow
# secrets are printed as shell `gh secret set` commands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN_KEYS="$(ls /tmp/sparkle*/bin/generate_keys /usr/local/bin/generate_keys 2>/dev/null | head -1 || true)"
if [ -z "$GEN_KEYS" ]; then
    echo "Sparkle tools not found. Fetch them first:" >&2
    echo "  curl -fsSL -o /tmp/sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz" >&2
    echo "  echo '015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc  /tmp/sparkle.tar.xz' | shasum -a 256 -c -" >&2
    echo "  tar xf /tmp/sparkle.tar.xz -C /tmp" >&2
    echo "Then re-run this script." >&2
    exit 1
fi

echo "==> Generating key pair (stored in the login keychain)"
"$GEN_KEYS"

echo
echo "==> Public key (add this as SUPublicEDKey):"
"$GEN_KEYS" -p

if [ "${1:-}" = "--to-file" ]; then
    DIR="${2:?usage: generate-sparkle-keys.sh --to-file DIR}"
    mkdir -p "$DIR"
    OUT="$DIR/downright-sparkle-ed25519.key"
    umask 077
    "$GEN_KEYS" -x "$OUT"
    echo
    echo "==> Private key exported to $OUT (chmod 600). Encrypt it (e.g. gpg) before"
    echo "    storing anywhere, and never keep the plaintext on a shared machine."
fi

cat <<'HELP'

==> Store these GitHub secrets in the `release` environment:

    gh secret set SPARKLE_ED25519_PRIVATE_KEY --env release \
        --body "$(generate_keys -x /dev/stdout 2>/dev/null || echo '<base64 seed from the exported key file>')"
    gh secret set SPARKLE_ED25519_PUBLIC_KEY --env release \
        --body '<the base64 public key printed above>'

Loss of the private key is an explicit recovery event (spec: failure policy),
NOT a reason to weaken validation — keep the encrypted backup.

Other release-environment secrets the workflow needs:
    DEVELOPER_ID_APPLICATION_P12_BASE64       # base64 of your Developer ID Application .p12
    DEVELOPER_ID_APPLICATION_P12_PASSWORD
    DEVELOPER_ID_APPLICATION_NAME             # "Developer ID Application: <name>"
    DEVELOPER_ID_APPLICATION_TEAM_ID
    APPLE_API_KEY_ID  APPLE_API_ISSUER_ID  APPLE_API_PRIVATE_KEY_P8
HELP
