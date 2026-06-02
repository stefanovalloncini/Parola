# Releasing Parola

Cutting a release is a few manual steps plus one script.

Sparkle is wired up. The hooks live in `ParolaApp/project.yml` (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`), `AppDelegate.swift` starts the updater on launch, and `SparkleUpdater.swift` handles channel selection. `SUFeedURL` and `SUPublicEDKey` ship empty in source — they need values before the first auto-update release, otherwise `SparkleUpdater.start()` returns early.

## One-time setup

1. **Apple Developer account** with a Developer ID Application certificate installed in your Keychain.
   ```sh
   security find-identity -v -p codesigning
   ```
   Note the team ID and the certificate name. Edit `ParolaApp/project.yml`:
   - Set `DEVELOPMENT_TEAM` to your team ID. `release.sh` refuses to run if this is empty.
   - Set `CODE_SIGN_IDENTITY` to `Developer ID Application: Your Name (TEAMID)`. The committed `-` is the ad-hoc fallback and produces an unsigned `.app` that Sparkle and Gatekeeper both reject.

   Regenerate the project: `(cd ParolaApp && xcodegen generate)`.

2. **App-specific password** for `notarytool`. Generate one at appleid.apple.com, then store it in your keychain:
   ```sh
   xcrun notarytool store-credentials --apple-id you@example.com --team-id TEAMID parola-notarize
   ```

3. **Sparkle EdDSA key pair**. Sparkle ships a `generate_keys` tool; after the first `xcodebuild` it sits under DerivedData. Run it once:
   ```sh
   ./generate_keys
   ```
   It writes the private key to your Keychain and prints the public key. Paste that public key into `ParolaApp/project.yml` under `SUPublicEDKey`.

4. **Appcast hosting on GitHub Releases**. Set `SUFeedURL` in `project.yml` to the latest-release asset URL so Sparkle always reads the newest appcast:

   ```
   https://github.com/stefanovalloncini/Parola/releases/latest/download/appcast.xml
   ```

   This requires the repo (or at least its Releases) to be **public**. Each release carries two assets: the notarized DMG and a cumulative `appcast.xml` listing every shipped `<item>`. Sparkle reads `appcast.xml` from the most recent release; each `<enclosure url>` points at that version's DMG (`…/releases/download/vX.Y.Z/Parola-X.Y.Z.dmg`).

After steps 1–4: `(cd ParolaApp && xcodegen generate)` and commit the updated `project.yml` (without the team ID if this is a public repo — use an overlay locally).

## Cutting a release

```sh
./scripts/bump.sh X.Y.Z              # bumps version, regenerates projects, runs full build + tests, then commits + tags
git push --follow-tags origin main

./scripts/release.sh --ship          # archive → export → codesign verify → DMG → notarize → staple → sign-update → print <item>
```

The `--ship` flag runs the full pipeline. Without it, `release.sh` stops after building the signed DMG and prints the remaining manual commands. The four steps that follow look like this when run by hand:

```sh
./scripts/release.sh                 # builds dist/Parola-X.Y.Z.dmg, verifies codesign
xcrun notarytool submit dist/Parola-X.Y.Z.dmg --keychain-profile parola-notarize --wait
xcrun stapler staple dist/Parola-X.Y.Z.dmg
./scripts/sign-update.sh dist/Parola-X.Y.Z.dmg
```

Tag the release `vX.Y.Z`, then append an `<item>` to `appcast.xml` (keep the full version history in the file):

```xml
<item>
    <title>Version X.Y.Z</title>
    <pubDate>...</pubDate>
    <enclosure
        url="https://github.com/stefanovalloncini/Parola/releases/download/vX.Y.Z/Parola-X.Y.Z.dmg"
        sparkle:version="X.Y.Z"
        sparkle:edSignature="..."
        length="..."
        type="application/octet-stream" />
</item>
```

Publish both the DMG and the updated `appcast.xml` as assets on the release:

```sh
gh release create vX.Y.Z dist/Parola-X.Y.Z.dmg appcast.xml --title "X.Y.Z" --notes "…"
```

Because `SUFeedURL` points at `releases/latest/download/appcast.xml`, existing installs pick up the new version on their next Sparkle check.

## Smoke test before announcing

- Open the released `.app` directly (no drag-install) from another Mac if possible.
- Run `parola --version` against the CLI binary inside the bundle.
- Confirm "Check for Updates…" in the menu finds the new version on a previous-version install.
