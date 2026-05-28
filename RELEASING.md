# Releasing QuickTranscript

These notes are for maintainers publishing public macOS builds.

## Notarized Public Builds

Unsigned or ad-hoc signed macOS apps can trigger Gatekeeper warnings. Public builds should be signed with a `Developer ID Application` certificate and notarized with Apple.

Store notarization credentials once:

```bash
xcrun notarytool store-credentials quicktranscript \
  --apple-id APPLE_ID \
  --team-id TEAM_ID \
  --password APP_SPECIFIC_PASSWORD
```

Build, submit to Apple, staple, validate, and zip:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE=quicktranscript \
./scripts/notarize_release.sh
```

The script produces a notarized `dist/QuickTranscript.app.zip`.
