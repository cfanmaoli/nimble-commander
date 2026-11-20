# Performance benchmarks

These scripts reproduce the numbers in [Docs/Performance.md](../../Docs/Performance.md). They need a
built-and-installed app (`Scripts/build_unsigned.sh`) and a big test directory.

## Preparing a test directory

```
cc -O2 -o /tmp/ncgen Scripts/perf/gen.c
mkdir -p /tmp/ncbench
/tmp/ncgen /tmp/ncbench/m1 1000000 8      # a million small files
```

Note that APFS/Spotlight will keep indexing the result for a while - wait until `mdutil`/`mds` calms
down, otherwise the enumeration timings are dominated by the indexing traffic.

## Instrumentation

The app prints its timings to stderr when `NC_PERF_LOG` is set:

```
NC_PERF_LOG=1 "/Applications/Nimble Commander-Fork.app/Contents/MacOS/Nimble Commander-Fork"
```

| line | what it measures |
|---|---|
| `[perf] preview n=... ready=...ms` | the first screenful put on screen while the rest is still being read |
| `[perf] fetch n=... enum=...ms build=...ms dir=...` | the enumeration itself (kernel-bound) and the listing build |
| `[perf] prepare n=... total=...ms` | the model preparation, done on a background queue |
| `[perf] ui n=... total=...ms` | the main-thread part of putting the data on screen |
| `[perf] incr ... patch=...ms` / `[perf] incr.ui ... total=...ms` | the response to a directory change (an incremental listing patch) |
| `[perf] stream n=... chunk=...` | one streamed chunk of a large listing; `n` reaches the entry count when the directory is complete |
| `[perf] build ... mem=...MB` | the deterministic size of the listing's own storage |

## Measuring

```
Scripts/perf/open_benchmark.sh /tmp/ncbench/m1     # first paint, load, footprint before/after
Scripts/perf/change_benchmark.sh /tmp/ncbench/m1   # response to a single change
```

**Always start the app with `-ApplePersistenceIgnoreState YES`** (the scripts do). Without it AppKit
restores the previously opened window - including a million-entry directory - and the "baseline"
already contains a listing, which makes every footprint number meaningless.

Two more caveats, both learned the hard way:

- the physical footprint is dominated by the free pages the allocator keeps after a big load, so it
  does not move when the steady-state data shrinks; use the `mem=` figure for regressions of the
  listing itself and `heap <pid>` (the `All zones` total) for the live data;
- `open -a <app> <directory>` while the app is being killed leaves a queued open event that fires on
  the next launch; the scripts wait a couple of seconds after `pkill` to avoid it.

## Finder tags and extended attributes

The listing reads Finder tags only for entries whose `getattrlistbulk` result does not carry
`EF_NO_XATTRS`. A file with any extended attribute therefore costs an `openat` +
`flistxattr` + `close`; files without xattrs are skipped cheaply.

This matters on directories where every file has an xattr: `x200k` below takes ~2.1 s instead of
~0.85 s for an equivalent directory without xattrs. Disabling Finder tags
(`filePanel.FinderTags.enable = false`) removes the pass and brings the same directory down to
~0.68 s. The tag scan runs on the background enumerators, so the first rows still appear quickly.

## The flat view and the find-files engines

`Docs/VFS-Peel-Evaluation.md` has the measurements for the newer work: the flat view can enumerate
the tree in two ways, and the find-files dialog has two search engines. Both choices are visible in
the config and both log which one ran.

| setting | values | what it does |
|---|---|---|
| `filePanel.general.flatScanStrategy` | `columnar` (default) / `composed` | columnar walks the tree directly and fills one listing input; composed builds a VFS listing per directory and composes them |
| `filePanel.general.flatScanThreads` | `0` (auto) or a number | how many directories the flat scan enumerates in parallel |
| `filePanel.general.flatViewMaxSeconds` | `30` (default), `0` = no limit | wall-clock budget; cloud providers answer in seconds per directory |
| `filePanel.general.flatViewSkipCloudStorage` | `true` (default) | leaves `Library/CloudStorage` and `Library/Mobile Documents` out of the flat view |
| `filePanel.general.parallelSearch` | `true` (default) | use the parallel engines in the find-files dialog when the host, filters and options allow |

Relevant log lines (all under `NC_PERF_LOG=1`):

```
[perf] flat root=... items=... dirs=... skipped=... truncated=... took=...ms scan=...ms compose=...ms fetch=...ms fold=...ms threads=... strategy=...
[perf] flat slowdir 1874ms /Users/.../Library/CloudStorage/...   # a directory that took >200ms
[perf] findfiles engine=parallel content=0 mask=*
```

To compare the two flat strategies by hand: set `flatScanStrategy` in the config, open a directory,
toggle the flat view (`View -> Flat View`) and read the `[perf] flat` line.

## Kernel baseline

`enum_baseline.c` answers "how much of an enumeration is the kernel's": it times `readdir` and
`getattrlistbulk` on a directory with no app code involved.

```
cc -O2 -o /tmp/nc_enum_baseline Scripts/perf/enum_baseline.c
/tmp/nc_enum_baseline /tmp/ncbench/m1 full
/tmp/nc_enum_baseline /tmp/ncbench/m1 nameonly
```

Measured on an Apple M5 Ultra (96 GB, macOS 27.2.1), external APFS volume, warm cache, app 1.9.3c,
default settings. "First rows" is the first `[perf] incr.ui`/`[perf] ui` for the opened directory;
"complete" is the last `[perf] stream` line reaching the entry count. Footprints are from
`vmmap` before/after.

| dataset | entries | `readdir` | `getattrlistbulk` full | first rows | complete | footprint |
|---|---|---|---|---|---|---|
| `m1` (1M files) | 1,000,003 | 0.63 s | 2.67 s | 0.38-0.40 s | **3.49 s** | 616-622 MB |
| `p200k` (200k files) | 200,001 | 0.05 s | 0.39 s | 0.37-0.39 s | **0.85 s** | 206-210 MB |
| `x200k` (200k files, each with xattr) | 200,001 | 0.05 s | 0.19 s | 0.39-0.42 s | **2.09 s** | 224-244 MB |
| `d200k` (200k empty dirs) | 200,001 | 0.10 s | 0.44 s | 0.55-0.56 s | **1.04 s** | 213-219 MB |

The `x200k` gap is the Finder-tag pass described above: the kernel enumeration is actually faster
than for `p200k`, but every file has a `user.ncbench` xattr, so the app opens and inspects it.

`open_benchmark.sh` still reports the baseline/loaded physical footprint; for very large streaming
listings its `tail` may not include the final `stream` line - look for the line whose `n` equals
the entry count when parsing the log by hand.

