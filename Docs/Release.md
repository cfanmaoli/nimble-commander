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
The NonMAS build configuration signs the app and the embedded privileged helper with the
maintainer's Apple Development identity (team `359W39ZS37`) by default - that is what makes
Administrator Mode work in a locally built release. `Scripts/export_options.plist` uses the
`development` export method, which needs no provisioning profile.

Distribution is a separate decision, driven by environment variables:
- `NC_CODESIGN_IDENTITY` - an identity (a Developer ID Application one for public releases) for
  `create-dmg --codesign`; without it the DMG itself is unsigned, the app inside is not affected.
- `NC_NOTARY_PROFILE` - a `notarytool` keychain profile; when set, `build_release.sh`/
  `build_nightly.sh` submit and staple the DMG. Notarisation requires Developer ID Application
  signing of the app and its nested code, so switch the project's NonMAS configuration to that
  identity first and point `NC_EXPORT_OPTIONS` at a `developer-id` export plist.
- `NC_EXPORT_OPTIONS` - your own export options plist.

CI does not sign anything: it builds unsigned DMGs, and the release notes explain that
Administrator Mode and the privileged helper need a signed build.

## Step 6: Write "What's New"
Update 'WHATS_NEW.md' with the list of changes since the last release.

### Release notes: signing and permissions

Every release note must state the signing status of *that* build and what it means for
Administrator Mode, with the same wording everywhere:

- Unsigned build: "This build is unsigned and not notarised. On the first launch allow it in
  System Settings -> Privacy & Security ("Open Anyway"), or remove the quarantine attribute after
  verifying the SHA256 below. Administrator Mode is unavailable in an unsigned build: macOS
  installs the privileged helper only for an application signed with an Apple-issued certificate
  of team 359W39ZS37 - an Apple Development or a Developer ID certificate."
- Apple Development / Developer ID signed build: "This build is signed with an Apple Development
  certificate (team 359W39ZS37) and is not notarised. On the first launch allow it in System
  Settings -> Privacy & Security ("Open Anyway"), or remove the quarantine attribute after
  verifying the SHA256 below. Administrator Mode works: the privileged helper is signed with the
  same certificate."

Every note offers both routes, followed by the command:

    xattr -dr com.apple.quarantine "/Applications/Nimble Commander-Fork.app"

(the helper's notes use `/Applications/ncrar-helper.app`). Say that the attribute records where the
download came from, so it should only be removed after the published SHA256 has been checked. Do
not claim that a Developer ID certificate is required for Administrator Mode - a team-signed Apple
Development certificate satisfies the same requirement.

## Step 7: Create the release tag and make the build

Pushes to `main` don't start CI; pull requests run the gate (Debug tests with clang-format and
clang-tidy) and stop there. Run the gate by hand when a commit is worth checking: `gh workflow run
build.yml --ref main`. Tick `full` for the complete matrix, the full clang-tidy and the integration
tests.

Create the version tag **before** building, on the exact commit that was tested, and check it out:

```sh
git tag -a vX.Y.Z -m "Nimble Commander-Fork vX.Y.Z"
git checkout vX.Y.Z
```

The working tree must be clean. Then package the release locally:

```sh
Scripts/build_release.sh
```

The script refuses a dirty or untagged HEAD, asserts that the app's
`CFBundleShortVersionString` matches the tag, and verifies the exported app's code signature and
team ID. It stays unsigned unless `NC_CODESIGN_IDENTITY` and `NC_NOTARY_PROFILE` are provided (see
step 5). Override the expected team with `NC_EXPECTED_TEAM_ID` if you deliberately use another one.

## Step 8: Create a GitHub Release (only if binaries are to be published)

Nightly builds are already published automatically: every scheduled run that actually builds (see
the preflight in `Docs/CI.md`) replaces the `nightly` pre-release with the unsigned DMG
`nimble-commander-fork-nightly.dmg`. The steps below are for a versioned release.

The fork deliberately doesn't distribute prebuilt binaries that contain the UnRAR library; the
clean variant is built locally by whoever needs it - see the README.

For a versioned release:
- Releases -> Draft a new release
- Select the existing tag `vX.Y.Z` created in step 7 (do not create the tag after building)
- Add the changelog and attach the DMG built by `Scripts/build_release.sh` in step 7. If it was
  built unsigned, write the same notice the nightly carries: the app is unsigned and not notarised,
  Administrator Mode and its privileged helper need a signed build.

## Step 9: Update the Sparkle feed
The application reads its update feed from the root of the `main` branch - see `SUFeedURL` in
`Source/NimbleCommander/NimbleCommander/Resources/NimbleCommander-NonMAS-Info.plist`. The feed is
generated from the GitHub releases of the fork: the latest tagged release is served as the regular
update, the rolling `nightly` pre-release lives in the `nightly` channel (Sparkle only offers it
to users who opt into that channel).

The release DMGs are signed with an EdDSA key; the public half is checked into the plist as
`SUPublicEDKey`, the private half is kept outside the repository in `~/.sparkle-fork/ed25519.key`
(mode 600) and must never be committed. The CI `build_unsigned.sh` stamps `CFBundleVersion` with
the number of commits, so build numbers only ever grow and Sparkle can tell which release is newer.

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
