# Versioning

Parola uses semantic versioning. One version string covers the app, the CLI, and
the MCP server — they ship together, so they never diverge.

## Where the numbers live

| Number | Source | Looks like |
|---|---|---|
| Marketing version | `ParolaCore/Sources/ParolaCore/Parola.swift` (`Parola.version`), mirrored into `MARKETING_VERSION` in both `project.yml` files | `0.2.0` |
| Build number | `CURRENT_PROJECT_VERSION` in both `project.yml` files | `1181` |

The build number is the commit count at release time, so it always rises and
never needs a decision. `scripts/bump.sh` writes both; nothing else should.

The marketing version reaches users through `parola --version`, the About sheet
and the Settings About pane (`AboutInfo.versionString`, which renders
`0.2.0 (1181)`), and the `appVersion` field the MCP bridge reports.

## Choosing the next version

`bump.sh` reads the commits since the last tag and picks the level itself:

```sh
scripts/bump.sh --dry-run     # show what it would do
scripts/bump.sh               # derive, confirm, build, test, commit, tag
```

Default is a patch bump. To ask for more, add a `Release:` trailer to the commit
that earns it — the subject line stays exactly as it always was:

```
Redesign Recently Deleted around retention time

Release: minor
```

Valid values are `major`, `minor`, and `patch`. The highest trailer in the range
wins, so one `Release: minor` anywhere since the last tag makes the whole release
a minor. Commits without a trailer are patches, which is most of them.

Rules of thumb:

- `patch` — bug fixes, performance, copy, anything a user won't have to relearn.
- `minor` — new features, new MCP tools or CLI flags, new settings.
- `major` — removing or renaming something people depend on: a CLI flag, an MCP
  tool, a `ParolaCore` public API, a document format that older builds can't read.

Two escape hatches:

```sh
scripts/bump.sh --level=minor    # override the trailers
scripts/bump.sh 1.0.0            # name the version outright
```

### Before 1.0

While the major version is 0, a `Release: major` trailer is treated as a minor
bump and `bump.sh` says so. Reaching 1.0.0 is a claim that the public surface is
stable, not something a trailer should trigger, so it takes the explicit form:

```sh
scripts/bump.sh 1.0.0
```

## What a bump does

1. Refuses to start on a dirty tree, a version that isn't higher, or an existing tag.
2. Checks that `Parola.swift` and both `project.yml` files already agree.
3. Writes the new version to all three, plus the new build number.
4. Prepends a `CHANGELOG.md` section built from the commit subjects in the range.
5. Regenerates both Xcode projects with `xcodegen`.
6. Runs `swift build`, `swift test`, and an `xcodebuild` build of the macOS app.
7. Commits as `release vX.Y.Z` and creates the annotated tag `vX.Y.Z`.

It never pushes. `git push --follow-tags origin main` is yours to run.

The changelog section starts as every subject in the range. Trim or reorder it,
then `git commit --amend` before pushing — worth doing when the range is long.

Pushing the tag runs `.github/workflows/release.yml`, which fails the build if the
tag disagrees with the version in source or if `CHANGELOG.md` has no section for
it. Signing and notarization stay on your Mac; CI has no certificates.

## Sparkle

`appcast.xml` at the repo root is the update feed, and `scripts/release.sh --ship`
adds each release to it. Two fields matter and they are not interchangeable:

- `sparkle:version` is the **build number**. Sparkle compares it against the
  installed app's `CFBundleVersion` to decide whether an update exists.
- `sparkle:shortVersionString` is the marketing version, and is only ever shown
  to the user.

Putting the marketing version in `sparkle:version` makes every installed copy look
newer than the feed, and the update is silently never offered.

See [RELEASING.md](../RELEASING.md) for the rest of the release ritual.
