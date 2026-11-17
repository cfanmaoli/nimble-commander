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
over a pipe. The GPL application contains no UnRAR code and no UnRAR headers. The helper's own code
is MIT-licensed; the UnRAR sources it bundles remain under the UnRAR license (see its `LICENSE` and
`LICENSE-MIT`). Distributing the two side by side is an aggregate of independent programs (GPLv3
section 5), not a combined work.

## Installing it

Download `ncrar-helper-<version>-macos-arm64.dmg` from the
[releases](https://github.com/cfanmaoli/ncrar-helper/releases), open it and drag
`ncrar-helper.app` into Applications. No installer and no script is involved - the application
looks for the helper inside that bundle.

The component may live in either of two places (the first one that exists and is executable wins):

1. `~/Applications/ncrar-helper.app/Contents/MacOS/ncrar-helper`;
2. `/Applications/ncrar-helper.app/Contents/MacOS/ncrar-helper`.

The executable must carry a valid code signature - an ad-hoc one is fine, a completely unsigned
binary is not: the application refuses to spawn it rather than running whatever happens to sit at
that path. The packaged helper is ad-hoc signed, so it passes this check.

The lookup is cached: the application searches for the helper once whenever the component is
enabled - at launch, or when the checkbox is toggled in **Preferences → Compression** - and reuses
the result. Installing or removing the bundle therefore requires toggling the checkbox off and on
once (or restarting the application) to be noticed. The same pane shows whether the helper is
installed and its version.

The component is ad-hoc signed and not notarised. macOS will refuse to launch it on the first run
until you allow it explicitly in **System Settings → Privacy & Security** ("Open Anyway").
Administrator Mode is unrelated: it runs the application's own privileged helper, which comes from
the signed build.

A binary is only built for arm64; the helper is a plain command line tool and can also be built
from source (see the project's README: `scripts/bootstrap-unrar.sh`, then CMake, then
`scripts/package.sh`).

The signature check is about integrity, not identity: any validly signed helper at that path is
accepted (the packaged one is ad-hoc signed), and the application does not pin a team or a
designated requirement - a locally built helper keeps working.

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

The helper is a separate component and may be older or newer than the application, so the first
lookup asks it with `ncrar-helper version` which protocol it speaks (`{"protocol":1,...}`). A
helper that reports an unknown protocol - or doesn't answer within a few seconds - is treated as
unusable and the libarchive reader takes over.

Every conversation is bounded: a listing or a link request gets 120 seconds in total, the wait for
the final exit status is 5 seconds, and a payload read fails if the helper stops writing for 60
seconds. A helper that hits any of these limits is terminated, so a stuck or hostile component
can't pin a VFS worker thread forever. The helper also starts with every file descriptor above
stderr closed - it never inherits the application's archives, sockets or database handles.

A read is validated against the helper's **exit status**, not just against the entry's declared
size. UnRAR reports a checksum mismatch or a damaged block only after the entry's bytes have been
handed out, so once the payload is complete the application waits for the child to exit and fails
the read if the status is non-zero - a stream is never reported as successfully read on the
strength of its length alone. A helper that is still running after producing the whole payload is
treated as a failure as well; the wait is bounded, and the helper is then terminated.

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