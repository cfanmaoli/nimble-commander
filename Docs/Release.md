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

## Step 5: Check the signing configuration
Signed packaging is opt-in and driven by environment variables - without them the DMG is unsigned:
- `NC_CODESIGN_IDENTITY` - a Developer ID Application identity for `create-dmg --codesign`.
- `NC_NOTARY_PROFILE` - a `notarytool` keychain profile; when set, `build_release.sh`/
  `build_nightly.sh` submit and staple the DMG.
- `NC_EXPORT_OPTIONS` - your own export options plist; the checked-in one references the upstream
  provisioning profile name.

CI does not sign anything: it builds unsigned DMGs, and the release attaches `UNSIGNED-BUILD.txt`
explaining that Administrator Mode and the privileged helper need a signed build.

## Step 6: Write "What's New"
Update 'WHATS_NEW.md' with the list of changes since the last release.

## Step 7: Make the build
Pushes to `main` and pull requests run the gate (Debug tests with clang-format and clang-tidy) and
stop there. The unsigned DMG is produced by the nightly run or by a manual dispatch of
`Build and Test` (`nimble-commander-fork-unsigned` artifact); tick `full` for the complete matrix,
the full clang-tidy and the integration tests. A versioned release is built by the `Release Build`
workflow from the tag.

## Step 8: Create a GitHub Release (only if binaries are to be published)

Nightly builds are already published automatically: every scheduled run that actually builds (see
the preflight in `Docs/CI.md`) replaces the `nightly` pre-release with the unsigned DMG
`nimble-commander-fork-nightly.dmg`. The steps below are for a versioned release.

The fork deliberately doesn't distribute prebuilt binaries that contain the UnRAR library; the
clean variant is built locally by whoever needs it - see the README.

For a versioned release:
- Releases -> Draft a new release
- Create new tag: `vX.Y.Z` (the new version)
- Target: `main`
- Add the changelog and attach the DMG from the `Release Build` workflow (it also attaches an
  `UNSIGNED-BUILD.txt` notice - the artifact is unsigned and not notarised).

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
