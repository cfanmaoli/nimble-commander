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
