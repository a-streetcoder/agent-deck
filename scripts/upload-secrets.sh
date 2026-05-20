#!/usr/bin/env bash
# Interactive helper that uploads the 7 GitHub Actions secrets needed by
# .github/workflows/release.yml.
#
# Run from the repo root, signed into gh:
#   gh auth status
#   ./scripts/upload-secrets.sh
#
# Each step is independently skippable — re-run any time to update a single
# secret. Nothing is logged to disk.

set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. brew install gh && gh auth login" >&2
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh CLI not authenticated. Run: gh auth login" >&2
  exit 2
fi

confirm() {
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

read_file_b64() {
  local path
  read -r -p "$1 " path
  path="${path/#\~/$HOME}"
  if [[ ! -f "$path" ]]; then
    echo "  Not found: $path" >&2
    return 1
  fi
  base64 -i "$path"
}

read_secret() {
  # No echo while typing.
  local val
  read -r -s -p "$1 " val
  echo
  printf '%s' "$val"
}

read_plain() {
  local val
  read -r -p "$1 " val
  printf '%s' "$val"
}

section() { echo; echo "── $1 ──"; }

section "1. MACOS_CERTIFICATE  (Developer ID Application .p12, base64-encoded)"
echo "Export the cert from Keychain Access (right-click → Export → .p12)."
if confirm "Upload MACOS_CERTIFICATE now?"; then
  b64=$(read_file_b64 "Path to .p12 file:") && \
    printf '%s' "$b64" | gh secret set MACOS_CERTIFICATE
fi

section "2. MACOS_CERTIFICATE_PWD  (password you chose when exporting the .p12)"
if confirm "Upload MACOS_CERTIFICATE_PWD now?"; then
  pwd=$(read_secret "Password:")
  printf '%s' "$pwd" | gh secret set MACOS_CERTIFICATE_PWD
fi

section "3. MACOS_KEYCHAIN_PASSWORD  (fresh password for the runner's temp keychain)"
echo "Invent a password — it's used only inside the CI runner's ephemeral keychain."
if confirm "Upload MACOS_KEYCHAIN_PASSWORD now?"; then
  pwd=$(read_secret "Password:")
  printf '%s' "$pwd" | gh secret set MACOS_KEYCHAIN_PASSWORD
fi

section "4. MACOS_SIGN_IDENTITY  (exact signing identity string)"
echo "Find yours with:  security find-identity -v -p codesigning"
echo 'Looks like:  Developer ID Application: Your Name (D37Z4S3883)'
if confirm "Upload MACOS_SIGN_IDENTITY now?"; then
  ident=$(read_plain "Identity:")
  printf '%s' "$ident" | gh secret set MACOS_SIGN_IDENTITY
fi

section "5. NOTARY_KEY  (App Store Connect API key .p8 file, base64-encoded)"
echo "Generate in App Store Connect → Users and Access → Keys (role: Developer)."
echo "Download the AuthKey_XXXXXXXX.p8 file (one chance only — save it)."
if confirm "Upload NOTARY_KEY now?"; then
  b64=$(read_file_b64 "Path to AuthKey_XXXXXXXX.p8:") && \
    printf '%s' "$b64" | gh secret set NOTARY_KEY
fi

section "6. NOTARY_KEY_ID  (the 10-character Key ID, shown next to the key name)"
if confirm "Upload NOTARY_KEY_ID now?"; then
  kid=$(read_plain "Key ID:")
  printf '%s' "$kid" | gh secret set NOTARY_KEY_ID
fi

section "7. NOTARY_ISSUER_ID  (Issuer ID UUID at the top of the Keys page)"
if confirm "Upload NOTARY_ISSUER_ID now?"; then
  iss=$(read_plain "Issuer ID:")
  printf '%s' "$iss" | gh secret set NOTARY_ISSUER_ID
fi

section "8. SPARKLE_PRIVATE_KEY  (raw EdDSA private key from generate_keys -x)"
echo "First run:  brew install --cask sparkle"
echo "Then:       generate_keys"
echo "Then:       generate_keys -x ~/sparkle_private_key.txt"
echo "Back it up to 1Password — lose it and you can never ship updates again."
if confirm "Upload SPARKLE_PRIVATE_KEY now?"; then
  path=$(read_plain "Path to sparkle_private_key.txt:")
  path="${path/#\~/$HOME}"
  if [[ -f "$path" ]]; then
    cat "$path" | gh secret set SPARKLE_PRIVATE_KEY
  else
    echo "  Not found: $path" >&2
  fi
fi

echo
echo "Current secrets:"
gh secret list
