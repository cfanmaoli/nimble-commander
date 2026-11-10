# Releasing a new version of Nimble Commander-Fork
*This is a checklist of various steps to take to release a new version, after the actual work is done.*

## Step 1: Update dependencies
In `3rd_Party/README.md`, go through each of the dependencies:
  - Check if there is a newer version, if so:
    - Update the `bootstrap.sh` script of that dependency, make sure it downloads and builds the new version.
    - Update the meta information in `3rd_Party/README.md` (version number, release date).
  - Run `3rd_Party/bootstrap.sh` to rebuild all dependencies in topological order.
  - Rebuild NC, run all tests to make sure everything is working correctly.
  - Commit all the changes.

## Step 2: Update `Help.md`
Go through the commits since the last release, and update `Docs/Help.md` accordingly.

## Step 3: Update the localization files
- In Xcode, go through each `Localizable.xcstrings` (filter the project by `localizable`) and XIB strings (filter the project by `(strings)`).
- Make sure that there's a green check mark next to each localization language (currently there's one, huh).
- Commit all the changes. 

## Step 4: Check the version works on the lowest supported macOS version

## Step 5: Check that MAS version builds and works as well
In case Provisioning Profiles or Signing Certificates have expired, renew them first.

## Step 6: Write "What's New"
Update 'WHATS_NEW.md' with the list of changes since the last release.

## Step 7: Make the build
The `Build and Test` workflow builds and packages an unsigned DMG on every push to `main`
(`nimble-commander-fork-unsigned` artifact). For the full matrix - all four configurations, the
full clang-tidy and the integration tests - trigger the same workflow manually with the `full`
input ticked, or wait for the nightly run.

## Step 8: Create a GitHub Release (only if binaries are to be published)

Nightly builds are already published automatically: every scheduled run that actually builds (see
the preflight in `Docs/CI.md`) replaces the `nightly` pre-release with the unsigned DMG
`nimble-commander-fork-nightly.dmg`. The steps below are for a versioned release.

The fork deliberately doesn't distribute prebuilt binaries that contain the UnRAR library, and the
clean variant is built locally by whoever needs it - see the README. Should that policy ever change:
- Releases -> Draft a new release
- Create new tag: `vX.Y.Z` (the new version)
- Target: `main`
- Add the changelog and attach the DMG from the CI artifact.

## Step 9: Update the Sparkle feed
The application reads its update feed from the root of the `main` branch - see `SUFeedURL` in
`Source/NimbleCommander/NimbleCommander/Resources/NimbleCommander-NonMAS-Info.plist`. The checked-in
`appcast.xml` is intentionally empty, so `Check for Updates` simply reports that the installed
version is the latest one.

If release builds are ever published, add an item to that file, for example:

```xml
<item>
  <title>Version X.Y.Z</title>
  <pubDate>...</pubDate>
  <sparkle:version>BUILD</sparkle:version>
  <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
  <enclosure url="https://github.com/cfanmaoli/nimble-commander/releases/download/vX.Y.Z/nimble-commander-fork-X.Y.Z.dmg"
             type="application/octet-stream" />
</item>
```

The fork doesn't set `SUPublicEDKey`, so the feed is served without EdDSA signatures. Before the
first real release, generate a key pair with Sparkle's `generate_keys` tool, put the public key
back into the plist, sign the appcast and keep the private key out of the repository.

## Step 10: Mac App Store
The fork doesn't ship the sandboxed MAS build.
