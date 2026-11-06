# Nimble Commander-Fork — `evil` branch

[**English**](README.md) | [简体中文](README.zh-Hans.md)

> ## ⚠️ This is the evil branch
>
> Unlike the [`main` branch](https://github.com/cfanmaoli/nimble-commander/tree/main), this branch
> bundles the proprietary **UnRAR** library to get the best possible RAR support. That makes the
> resulting binary impossible to distribute under the project's GPLv3 license.
>
> - **No prebuilt binaries, DMGs, nightly builds or releases are published for this branch — ever.**
> - **Build it yourself** if you want to use it (see [Docs/Building.md](Docs/Building.md)).
> - **Do not redistribute** anything built from this branch.
>
> It exists for personal use only. The clean, GPLv3-compatible variant — where RAR archives are read
> through libarchive instead — lives on the [`main` branch](https://github.com/cfanmaoli/nimble-commander/tree/main).

---

Nimble Commander-Fork is a community-maintained fork of
[Nimble Commander](https://github.com/mikekazakov/nimble-commander) — a free dual-pane file manager
for macOS focused on speed, keyboard-driven navigation and flexibility. Upstream development stopped
after the 1.9.0 release, so the fork continues from that point.

## What this branch adds on top of `main`

Everything from the `main` branch, plus:

- **RAR via UnRAR** — archives are listed and extracted with the official UnRAR 7.3.2 library
  instead of libarchive, giving correct behaviour for solid archives and a much faster listing of
  large ones.
- **Password-protected RARs** — the password prompt works for encrypted headers and payloads.
- **Multi-volume RARs** — `.part1.rar` / `.r00` sets are followed automatically.

Everything else (Apple Silicon only builds, language packs, extra themes, Trash support, fixes) is
shared with `main`.

## Performance with huge directories

The fork carries a set of changes aimed at directories with hundreds of thousands of entries
(a million-entry directory is the benchmark). See [Docs/Performance.md](Docs/Performance.md) for
the measurements and the reasoning; the short version:

| | before | now |
|---|---|---|
| first paint of a 1M-entry directory | ~2.2 s | **~34 ms** (a preview listing goes on screen while the rest is read) |
| a single change in a 1M-entry directory | 2.4 s (a full reload with the default view options) | **~40 ms** (path-level FSEvents + an incremental listing patch) |
| reading the directory itself | ~5.7 s of CPU | ~2.35 s, of which 2.17 s is the kernel enumeration |
| resident memory, 1M entries | ~650 MB | ~283 MB by default, ~252 MB in the lazy mode |

Two optional settings trade information for memory on very large directories. They live in
`~/Library/Application Support/Nimble Commander-Fork/Config/Config.json` and are off by default:

- `filePanel.general.lazyDates` - the enumeration skips the five timestamp columns (20 MB per
  million entries); the date columns fill in as you scroll (the panel stats the visible rows).
- `filePanel.general.lazySizes` - the same for the sizes (another 8 MB).

With either of them on, sorting by the affected column reloads the directory with the full
attributes first, and the columns show `--` until a row has been fetched.

## Building

See [Docs/Building.md](Docs/Building.md). The bundled libraries are precompiled for arm64; run
`3rd_Party/bootstrap.sh` to rebuild them from their sources. Remember that you are building a
binary that includes UnRAR and therefore must not be published.

## License

The project's own source code is distributed under the GNU General Public License version 3,
Copyright (C) 2013-2026 Michael Kazakov and the contributors.

The bundled UnRAR source code is `(c) Alexander Roshal` and is distributed under its own license,
which permits use in any software but requires the license text to be kept together with the
package. Combining it with GPLv3 code is what makes this branch non-distributable; this is why no
builds are provided.
