# Releasing Parola

Cutting a new release is a few manual steps plus one script.

> **Sparkle auto-updates are not wired up yet.** Adding the Sparkle SPM dep made
> `xcodebuild` deterministically hang at "Resolve Package Graph" in this dev
> environment. The hook spots (Info.plist keys, AppDelegate updater controller,
> "Check for Updates…" menu item) are intentionally left out. When you're ready
> to ship updates, see the "Wiring up Sparkle later" section at the bottom of
> this file.

## One-time setup

1. **Apple Developer Program account** with a Developer ID Application certificate installed in your Keychain.
   ```sh
   security find-identity -v -p codesigning
   ```
   Note the team ID and the certificate name. Edit `ParolaApp/project.yml`:
   - Set `DEVELOPMENT_TEAM` to your team ID.
   - Set `CODE_SIGN_IDENTITY` to `Developer ID Application: Your Name (TEAMID)` (or leave `Apple Development` for local builds).
   Regenerate the project: `(cd ParolaApp && xcodegen generate)`.

2. **App-specific password** for `notarytool`. Generate it at appleid.apple.com. Store it in your keychain:
   ```sh
   xcrun notarytool store-credentials --apple-id you@example.com --team-id TEAMID parola-notarize
   ```

3. **Sparkle EdDSA key pair**. The Sparkle package ships a `generate_keys` tool; after your first `xcodebuild` it lives somewhere under DerivedData. Run it once:
   ```sh
   ./generate_keys
   ```
   It stores the private key in your Keychain and prints the public key. Paste the public key into `ParolaApp/project.yml` under `SUPublicEDKey`.

4. **Appcast hosting**. Pick a HTTPS URL you control (GitHub Pages, Cloudflare Pages, your own host). Set `SUFeedURL` in `project.yml` to match.

## Cutting a release

```sh
# Bump version in ParolaApp/project.yml (MARKETING_VERSION, CURRENT_PROJECT_VERSION).
./scripts/release.sh                        # builds dist/Parola-X.Y.Z.dmg

# Notarize.
xcrun notarytool submit dist/Parola-X.Y.Z.dmg \
    --keychain-profile parola-notarize \
    --wait

# Staple the notarization ticket so the DMG works offline.
xcrun stapler staple dist/Parola-X.Y.Z.dmg

# Sign the update for Sparkle.
./scripts/sign-update.sh dist/Parola-X.Y.Z.dmg

# Upload the DMG (e.g. to GitHub Releases or your CDN), then append to appcast.xml:
#   <item>
#     <title>Version X.Y.Z</title>
#     <pubDate>...</pubDate>
#     <enclosure
#       url="https://parola.app/releases/Parola-X.Y.Z.dmg"
#       sparkle:version="X.Y.Z"
#       sparkle:edSignature="..."
#       length="..."
#       type="application/octet-stream" />
#   </item>
```

Push the updated `appcast.xml` to its host. Existing installs will pick up the new version on the next Sparkle check.

## Smoke test before announcing

- Open the released `.app` directly (don't drag-install) from another Mac if possible.
- Run `parola --version` from the CLI binary inside the bundle.

## Wiring up Sparkle later

When you're ready to enable auto-updates:

1. In `ParolaApp/project.yml`, restore:

   ```yaml
   packages:
     ParolaCore: { path: ../ParolaCore }
     Sparkle:
       url: https://github.com/sparkle-project/Sparkle.git
       from: "2.6.0"
   targets:
     ParolaApp:
       info:
         properties:
           # …existing keys…
           SUFeedURL: https://parola.app/appcast.xml
           SUPublicEDKey: <PASTE_PUBLIC_KEY_FROM_generate_keys>
           SUEnableAutomaticChecks: true
       dependencies:
         - { package: ParolaCore, product: ParolaCore }
         - { package: Sparkle,    product: Sparkle }
   ```

2. In `ParolaApp/ParolaApp/AppDelegate.swift`, add the Sparkle imports and an updater controller:

   ```swift
   @preconcurrency import Sparkle
   // inside AppDelegate:
   let updaterController = SPUStandardUpdaterController(
       startingUpdater: true,
       updaterDelegate: nil,
       userDriverDelegate: nil
   )
   ```

3. In `ParolaApp.swift`, add a "Check for Updates…" command:

   ```swift
   CommandGroup(after: .appInfo) {
       Button("Check for Updates…") { appDelegate.updaterController.checkForUpdates(nil) }
   }
   ```

4. Run `(cd ParolaApp && xcodegen generate)` and build once. If the build hangs at "Resolve Package Graph", clean DerivedData and retry — Sparkle's binary artifact resolver can stall on the first fetch. Once compiled, the binaries are cached.

5. Use `./scripts/sign-update.sh` for each release as documented above.
