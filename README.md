# Nimble Commander-Fork

[**English**](README.md) | [简体中文](README.zh-Hans.md)

Nimble Commander-Fork is a community-maintained fork of
[Nimble Commander](https://github.com/mikekazakov/nimble-commander) — a free dual-pane file manager
for macOS focused on speed, keyboard-driven navigation and flexibility.

Upstream development stopped after the 1.9.0 release, so this fork continues from that point. The
user interface, documentation and file formats are inherited from upstream; the application name was
changed to avoid confusion with the original project.

![](Docs/nc.png)

## What this fork changes

- **Simplified Chinese out of the box** — the fork ships a thorough zh-Hans localization (menus,
  preferences, file-operation dialogs, error messages, permission requests; about 1,460 strings). A
  Chinese system starts in Chinese, with no language pack to download; see
  [README.zh-Hans.md](README.zh-Hans.md).
- **Apple Silicon only** — the app and all bundled libraries are built for arm64; Intel support was
  dropped.
- **Language packs** — *Preferences → Language* can export the interface strings of the current
  language as JSON, import a translation back, and switch between the built-in languages and any
  imported pack without Xcode, a rebuild or a re-sign. See
  [Tools/language-packs.md](Tools/language-packs.md).
- **More bundled themes** — Solarized (light/dark), Nord, Dracula, Gruvbox (light/dark), One Dark,
  Tokyo Night, Catppuccin (Mocha/Latte), GitHub Dark and Monokai, next to the original Light, Dark
  and Classic themes.
- **Flat view** — `View > Flat View` (`Option + Command + B`) lists the entire subtree of the
  current directory in one panel, so a deep folder tree can be worked with without navigating in
  and out.
- **Trash support** — browse `~/.Trash` and the per-volume trashes (`/Volumes/*/.Trashes/<uid>`),
  empty all of them at once and put items back to their original locations.
- **RAR support without proprietary code** — RAR archives are read through libarchive, the same
  backend that upstream uses; no third-party RAR implementation is bundled with this branch.
- **Smaller fixes** — cancellable archive scans, pinyin-initial quick filtering, a regular-expression
  quick filter mode, mouse back/forward navigation, and a privileged helper that keeps working with
  locally signed builds.


## Performance with huge directories

The fork also carries a set of changes aimed at directories with hundreds of thousands of entries
(a million-entry directory is the benchmark). See [Docs/Performance.md](Docs/Performance.md) for the
measurements and the reasoning; the short version:

| | before | now |
|---|---|---|
| first paint of a 1M-entry directory | ~2.2 s | **~34 ms** (a preview listing goes on screen while the rest is read) |
| a single change in a 1M-entry directory | 2.4 s (a full reload with the default view options) | **~40 ms** (path-level FSEvents + an incremental listing patch) |
| reading the directory itself | ~5.7 s of CPU | ~2.35 s, of which 2.17 s is the kernel enumeration |
| resident memory, 1M entries | ~650 MB | ~283 MB by default, ~252 MB in the lazy mode |

The flat view and the find-files dialog have their own fast paths (a column-oriented tree scan and
parallel filename/content searches); they are described, with measurements, in
[Docs/VFS-Peel-Evaluation.md](Docs/VFS-Peel-Evaluation.md).

Two optional settings trade information for memory on very large directories. They live in
`~/Library/Application Support/Nimble Commander-Fork/Config/Config.json` and are off by default:

- `filePanel.general.lazyDates` - the enumeration skips the five timestamp columns (20 MB per
  million entries); the date columns fill in as you scroll (the panel stats the visible rows).
- `filePanel.general.lazySizes` - the same for the sizes (another 8 MB).

With either of them on, sorting by the affected column reloads the directory with the full
attributes first, and the columns show `--` until a row has been fetched.
## Building from source

See [Docs/Building.md](Docs/Building.md). The bundled libraries are precompiled for arm64; run
`3rd_Party/bootstrap.sh` to rebuild them from their sources.

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
