#!/bin/bash
# One-time setup for auto-updates. Run on your Mac from the repo folder:
#   ./scripts/setup-sparkle-keys.sh
#
# Creates (or reuses) the EdDSA key that signs updates. The private key lives in your
# login Keychain and goes into the SPARKLE_PRIVATE_KEY GitHub secret; the public key is
# written to Resources/SparklePublicKey.txt, which you commit.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -d .build/artifacts ]] || swift package resolve
GEN="$(find .build/artifacts -name generate_keys -type f | head -1)"
if [[ -z "$GEN" ]]; then echo "Sparkle's generate_keys not found. Run ./build-app.sh once, then retry." >&2; exit 1; fi

# Creates a key in the Keychain if there isn't one yet; prints the public key either way.
OUTPUT="$("$GEN" 2>&1 || true)"
PUBLIC="$("$GEN" -p 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "$PUBLIC" ]]; then
  PUBLIC="$(printf '%s\n' "$OUTPUT" | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | head -1)"
fi
if [[ -z "$PUBLIC" ]]; then printf '%s\n' "$OUTPUT" >&2; echo "Couldn't read the public key." >&2; exit 1; fi
printf '%s\n' "$PUBLIC" > Resources/SparklePublicKey.txt
echo "✓ Public key saved to Resources/SparklePublicKey.txt"

KEYFILE="$(mktemp -u)"
trap 'rm -f "$KEYFILE"' EXIT
"$GEN" -x "$KEYFILE" >/dev/null
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh secret set SPARKLE_PRIVATE_KEY --repo zesskyo/LiteCap < "$KEYFILE"
  echo "✓ Private key saved as the SPARKLE_PRIVATE_KEY repository secret"
else
  echo
  echo "Add the line below as a repository secret named SPARKLE_PRIVATE_KEY:"
  echo "  GitHub → zesskyo/LiteCap → Settings → Secrets and variables → Actions → New repository secret"
  echo
  cat "$KEYFILE"
  echo
  echo "Keep it private. A copy stays in your Keychain (item: \"Private key for signing Sparkle updates\")."
fi
echo
echo "Then commit the public key:"
echo "  git add Resources/SparklePublicKey.txt && git commit -m 'Add update signing key' && git push"
