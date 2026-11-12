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
`Source/NimbleCommander/NimbleCommander/Resources/NimbleCommander-NonMAS-Info.plist`. The feed is
generated from the GitHub releases of the fork: the latest tagged release is served as the regular
update, the rolling `nightly` pre-release lives in the `nightly` channel (Sparkle only offers it
to users who opt into that channel).

The release DMGs are signed with an EdDSA key; the public half is checked into the plist as
`SUPublicEDKey`, the private half is kept outside the repository in `~/.sparkle-fork/ed25519.key`
(mode 600) and must never be committed. Both the local `sign-install-fork.sh` and the CI
`build_unsigned.sh` stamp `CFBundleVersion` with the number of commits, so build numbers only
ever grow and Sparkle can tell which release is newer.

After publishing a release (and after the nightly is refreshed), regenerate the feed and commit it:

```sh
Scripts/update_appcast.py --sign-update /path/to/Sparkle/bin/sign_update
git add appcast.xml && git commit -m "Update the Sparkle feed"
git push
```

The script downloads the DMG assets, reads their versions from the application bundles, signs each
archive and writes `appcast.xml` with the enclosures pointing at the release assets on GitHub. Pass
`--dry-run` to inspect the feed, `--tag vX.Y.Z` to pin a specific release and `--no-nightly` to
leave the nightly out. The Sparkle tools ship in the official Sparkle release archive
(`Sparkle-<version>.tar.xz`).

## Step 10: Mac App Store
The fork doesn't ship the sandboxed MAS build.
