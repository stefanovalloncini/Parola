# Releasing Parola

Cutting a release is two scripts and a push. Version numbering lives in [docs/versioning.md](docs/versioning.md).

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
./scripts/bump.sh                    # derives the version from Release: trailers, then builds, tests, commits, tags
git push --follow-tags origin main

./scripts/release.sh --ship          # archive → export → codesign verify → DMG → notarize → staple → sign-update → appcast.xml
```

How the version is chosen, what the `Release:` trailer does, and why 1.0.0 is
explicit: [docs/versioning.md](docs/versioning.md). Check the plan first with
`./scripts/bump.sh --dry-run`.

The `--ship` flag runs the full pipeline. Without it, `release.sh` stops after building the signed DMG and prints the remaining manual commands. The four steps that follow look like this when run by hand:

```sh
./scripts/release.sh                 # builds dist/Parola-X.Y.Z.dmg, verifies codesign
xcrun notarytool submit dist/Parola-X.Y.Z.dmg --keychain-profile parola-notarize --wait
xcrun stapler staple dist/Parola-X.Y.Z.dmg
./scripts/sign-update.sh dist/Parola-X.Y.Z.dmg
```

`--ship` also writes the release into `appcast.xml`, creating the file on the first
run and inserting later releases above the previous ones. Each item looks like this:

```xml
<item>
    <title>Version X.Y.Z</title>
    <pubDate>...</pubDate>
    <sparkle:version>1181</sparkle:version>
    <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
    <enclosure
        url="https://github.com/stefanovalloncini/Parola/releases/download/vX.Y.Z/Parola-X.Y.Z.dmg"
        sparkle:edSignature="..."
        length="..."
        type="application/octet-stream" />
</item>
```

`sparkle:version` is the build number (`CFBundleVersion`), read from the app that
was just built. Sparkle compares it against the installed copy's `CFBundleVersion`,
so putting the marketing version there makes every install look newer than the feed
and no update is ever offered. `sparkle:shortVersionString` is what users see.

Commit the updated `appcast.xml`, then publish it alongside the DMG:

```sh
git add appcast.xml && git commit -m "appcast: X.Y.Z" && git push
gh release create vX.Y.Z dist/Parola-X.Y.Z.dmg appcast.xml --title "X.Y.Z" --notes-from-tag
```

Because `SUFeedURL` points at `releases/latest/download/appcast.xml`, existing installs pick up the new version on their next Sparkle check.

Pushing the tag also runs `.github/workflows/release.yml`, which rebuilds and refuses
the tag if it disagrees with the version in source or `CHANGELOG.md` has no section
for it. It does not sign or notarize — CI holds no certificates.
