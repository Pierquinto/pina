#!/bin/bash
# Prepara una release firmata e notarizzata: dist/Pina-<versione>.zip
#
# Serve un certificato "Developer ID Application" nel Portachiavi e un profilo
# notarytool salvato con:
#   xcrun notarytool store-credentials <profilo> --apple-id … --team-id …
#
# Uso: SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profilo> scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?imposta SIGN_IDENTITY (nome o impronta SHA-1 del certificato Developer ID)}"
: "${NOTARY_PROFILE:?imposta NOTARY_PROFILE (profilo salvato con notarytool store-credentials)}"

VERSIONE=$(sed -n 's/^VERSIONE="\(.*\)"/\1/p' build.sh)
DIST="dist"
APP="$DIST/Pina.app"
ZIP="$DIST/Pina-$VERSIONE.zip"

rm -rf "$DIST"
mkdir -p "$DIST"
DEST="$DIST" ./build.sh

# Hardened runtime e timestamp sono obbligatori per la notarizzazione.
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# Il ticket va attaccato all'app, poi lo zip si rifà con l'app "graffettata".
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

shasum -a 256 "$ZIP"
echo "Pronta: $ZIP"
