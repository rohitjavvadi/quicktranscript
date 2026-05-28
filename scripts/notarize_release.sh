#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "SIGN_IDENTITY is required, for example:"
  echo '  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARYTOOL_PROFILE=quicktranscript ./scripts/notarize_release.sh'
  exit 1
fi

if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
  echo "NOTARYTOOL_PROFILE is required."
  echo "Create it once with:"
  echo "  xcrun notarytool store-credentials quicktranscript --apple-id APPLE_ID --team-id TEAM_ID --password APP_SPECIFIC_PASSWORD"
  exit 1
fi

SIGN_IDENTITY="$SIGN_IDENTITY" ./package_app.sh

ditto -c -k --keepParent dist/QuickTranscript.app dist/QuickTranscript.app.zip
xcrun notarytool submit dist/QuickTranscript.app.zip \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait

xcrun stapler staple dist/QuickTranscript.app
xcrun stapler validate dist/QuickTranscript.app

ditto -c -k --keepParent dist/QuickTranscript.app dist/QuickTranscript.app.zip
shasum -a 256 dist/QuickTranscript.app.zip
