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

## The lazy modes

`filePanel.general.lazyDates` and `filePanel.general.lazySizes` in
`~/Library/Application Support/Nimble Commander-Fork/Config/Config.json` make the enumeration skip
the timestamp and size columns and fetch them for the rows the panel actually shows. They are off by
default; with both on, a million-entry directory costs ~55MB in the listing instead of ~81MB.
