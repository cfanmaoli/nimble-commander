[![Build and Test](https://github.com/cfanmaoli/nimble-commander/actions/workflows/build.yml/badge.svg)](https://github.com/cfanmaoli/nimble-commander/actions/workflows/build.yml)

# Nimble Commander-Fork

[**English**](README.md) | [简体中文](README.zh-Hans.md)

Nimble Commander-Fork is a community-maintained fork of
[Nimble Commander](https://github.com/mikekazakov/nimble-commander) — a free dual-pane file manager
for macOS focused on speed, keyboard-driven navigation and flexibility.

Upstream development stopped after the 1.9.0 release, so this fork continues from that point. The
user interface, documentation and file formats are inherited from upstream; the application name was
changed to avoid confusion with the original project.

The project website, with downloads and release notes, is
[cfanmaoli.github.io/nc-website](https://cfanmaoli.github.io/nc-website/).

![](Docs/nc.png)

## What this fork changes

- **Apple Silicon only** — the app is built for arm64 only and Intel support was dropped. Two
  bundled third-party frameworks (Sparkle and LetsMove) still ship as universal binaries, but their
  x86_64 slices are never used.
- **Language packs** — the app ships English and Simplified Chinese only; translations for other
  languages are collected in [nc-language](https://github.com/cfanmaoli/nc-language) and can be
  imported at any time. *Preferences → Language* switches between the built-in languages and the
  imported packs, and can export the current strings as JSON - no Xcode, rebuild or re-sign needed.
  See [Tools/language-packs.md](Tools/language-packs.md).
- **More bundled themes** — Solarized (light/dark), Nord, Dracula, Gruvbox (light/dark), One Dark,
  Tokyo Night, Catppuccin (Mocha/Latte), GitHub Dark and Monokai, next to the original Light, Dark
  and Classic themes.
- **Flat view** — `View > Flat View` (`Option + Command + B`) lists the entire subtree of the
  current directory in one panel, so a deep folder tree can be worked with without navigating in
  and out.
- **Trash support** — browse `~/.Trash` and the per-volume trashes (`/Volumes/*/.Trashes/<uid>`),
  empty all of them at once and put items back to their original locations.
- **Optional RAR support** — RAR archives are read through libarchive out of the box. If you need
  full RAR support (solid archives, encrypted headers and payloads, multi-volume sets), install the
  separate [ncrar-helper.app](https://github.com/cfanmaoli/ncrar-helper/releases) component: it is
  an independent program whose own code is MIT-licensed, while the UnRAR sources it bundles remain
  under the UnRAR license - the application itself still contains no proprietary code. Enable it in
  *Preferences → Compression*, which also shows whether it is installed and which version it is.
  See [Docs/RarSupport.md](Docs/RarSupport.md).
- **Compression preferences** — the archive format (zip, 7z, tar), the algorithm and the level used
  by the compress dialog are configurable in *Preferences → Compression*.
- **Smaller fixes** — cancellable archive scans, pinyin-initial quick filtering, a regular-expression
  quick filter mode, mouse back/forward navigation, and a privileged helper that keeps working with
  locally signed builds.


## Performance with huge directories

The fork also carries a set of changes aimed at directories with hundreds of thousands of entries
(a million-entry directory is the benchmark). See [Docs/Performance.md](Docs/Performance.md) for the
measurements and the reasoning; the short version:

| | before | now |
|---|---|---|
| first paint of a 1M-entry directory | ~2.2 s | **~0.4 s** (4,096 rows on screen; the rest streams in) |
| a single change in a 1M-entry directory | 2.4 s (a full reload with the default view options) | **~135 ms** (path-level FSEvents + an incremental listing patch) |
| opening a 1M-entry directory completely | ~5.7 s of CPU | **~3.5 s wall**, of which 2.67 s is the kernel enumeration |
| physical footprint, 1M entries | ~650 MB | **~620 MB** (the listing itself is ~81 MB) |

These numbers were re-measured on 1.9.3c with an Apple M5 Ultra, 96 GB, macOS 27.2.1, a 1M-file
directory on an external APFS volume and a warm file cache. A 200k-file directory whose files all
carry an extended attribute opens in ~2.1 s instead of ~0.85 s, because Finder-tag loading has to
open every such file; [Scripts/perf/README.md](Scripts/perf/README.md) has the details and the
other test datasets.

The flat view and the find-files dialog have their own fast paths (a column-oriented tree scan and
parallel filename/content searches); they are described, with measurements, in
[Docs/VFS-Peel-Evaluation.md](Docs/VFS-Peel-Evaluation.md).
## Building from source

See [Docs/Building.md](Docs/Building.md). The bundled libraries are precompiled; the app links
their arm64 slices. Run `3rd_Party/bootstrap.sh` to rebuild them from their sources.

## Documentation

The user guide lives in [Docs/Help.md](Docs/Help.md).

## Changelog

Details about each released version can be found in [WHATS_NEW.md](WHATS_NEW.md).

## Contributing

Contributions, bug reports and translations are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
The fork itself is written by DeepSeek under continuous human supervision and review.

## License

Nimble Commander-Fork is distributed under the GNU General Public License version 3.
Copyright (C) 2013-2026 Michael Kazakov, and the Nimble Commander-Fork contributors for their changes.

The optional RAR support component (`ncrar-helper.app`) is a separate program: its own code is
MIT-licensed and the UnRAR sources it bundles are distributed under the UnRAR license by RARLAB. It
is not part of this application and is not covered by the GPLv3.
