# Optional RAR support

Nimble Commander-Fork reads RAR archives through libarchive by default. Better RAR support --
correct handling of solid archives, encrypted headers and payloads, and automatic following of
multi-volume sets -- is available through a **separate, optional component**: `ncrar-helper`.

## Why it is a separate program

The best RAR reader is RARLAB's UnRAR, but its license is not compatible with the GPLv3: it forbids
using the sources to build a RAR-compatible archiver, and the GPL does not allow such an extra
restriction on a combined work. Linking UnRAR into the application would make the resulting binary
non-distributable.

`ncrar-helper` therefore is a **standalone executable** that the application starts and talks to
over a pipe. The GPL application contains no UnRAR code and no UnRAR headers; the helper is
distributed separately under the UnRAR license (see its `LICENSE`). Distributing the two side by
side is an aggregate of independent programs (GPLv3 section 5), not a combined work.

## Installing it

Open `ncrar-helper-<version>-macos-arm64.dmg` and drag `ncrar-helper.app` into Applications. No
installer and no script is involved - the application looks for the helper inside that bundle.

The component may live in either of two places (the first one that exists and is executable wins):

1. `~/Applications/ncrar-helper.app/Contents/MacOS/ncrar-helper`;
2. `/Applications/ncrar-helper.app/Contents/MacOS/ncrar-helper`.

The application checks for the helper on every archive open, so installing or removing the bundle
does not require a restart.

The component is ad-hoc signed and not notarised. If Gatekeeper quarantines the bundle after a
download, clear the attribute once:

```sh
xattr -dr com.apple.quarantine /Applications/ncrar-helper.app
```

A binary is only built for arm64; the helper is a plain command line tool and can also be built
from source (see the project's README: `scripts/bootstrap-unrar.sh`, then CMake, then
`scripts/package.sh`).

## How the application uses it

When opening a file as an archive, the application:

1. finds the helper (see above);
2. reads the first bytes of the file and checks for the RAR signature (`Rar!\x1a\x07`);
3. only then asks the helper for the listing; non-RAR files never touch it;
4. if the helper is missing or fails, falls back to the libarchive-based reader exactly as before.

Passwords are passed to the helper through its environment, never on the command line, and the
existing password prompt is reused when an archive is detected as encrypted.

The helper is invoked as a plain command line tool: the listing is fetched once with
`ncrar-helper list` when the archive is opened, every entry read starts a fresh
`ncrar-helper read`, and a RAR4 symlink target is requested with `ncrar-helper link`. No helper
process is kept alive between operations.

Symlinks are followed when walking a path: `Stat`, directory listings and file opens resolve every
link component to the entry it points at, while a lookup with `F_NoFollow` and a directory
listing still report the link itself as a link. RAR5 stores link targets in the header; for RAR4
unix symlinks, whose target lives in the entry payload, the target is requested from the helper's
`link` command on demand and cached.

Entries that carry Unix attributes expose their real mode (type and permission bits, including
setuid/setgid/sticky) through `Stat` and directory listings. Entries without them keep the
synthetic `0644`/`0755` modes, and directories are always directories. Thumbnails are produced
for archive entries, matching the libarchive-based reader.

## Limitations

- Every entry read starts a fresh helper process, so previewing many entries of a big solid archive
  is slower than it could be.
- RAR4 hardlinks whose target isn't stored in the header cannot be resolved: UnRAR needs the target
  file to exist while extracting. RAR5 hardlinks normally carry the target and work.
- RAR4 link targets are returned as stored by the archive. Absolute targets and targets containing
  `..` that UnRAR considers unsafe can be refused during the temporary extraction; such a link is
  listed but its target cannot be resolved.
- File names are used as the helper reports them (UTF-8, `/`-separated); legacy code pages and
  Unicode normalization are not applied.
- AppleDouble/xattrs are not handled, and the helper's list does not carry Unix owner/group names.
- Directory entries keep the synthetic `0755` mode: the helper reports a mode only when the
  header carries the `0x8000` marker, which real Unix directory entries don't (their `S_IFDIR`
  bit is `0x4000`).