# Rust core — integration notes

This file records how the Rust part is built into the app and what it is (and is not) used for yet.
The design comes from the feasibility evaluation in
`nc-rewrite-eval/Nimble-Commander-Fork-Swift-Rust-重构可行性评估.md` plus
`research/01-interop.md`, `research/02-prior-art-cost.md` and `research/03-spike-report.md`.

## What the evaluation said (and what we follow)

- Do not rewrite the app: 153k lines, 8–25 person-years, and the most expensive part is validation,
  not the language.
- Migrate one read-only vertical slice at a time, with the C++ implementation kept as an oracle.
- The C ABI boundary is essentially free (0.44 ns/call in the spike) and adds ~1.3–1.5 MiB to the
  binary, so the boundary itself is not a reason to avoid Rust.
- Swift must not call into the C++ core directly; `232` throws would abort the process. This fork
  keeps the ObjC++ façade.

## Integration (what landed)

```
rust/
  include/nc_core.h        the C ABI
  nc_core/src/lib.rs       the library (no third-party deps)
  build.sh                 builds target/release/libnc_core.a
```

- A "Build Rust core" shell-script phase was added to the `NimbleCommander-Unsigned` target; it runs
  `rust/build.sh` before compiling.
- That target links `-lnc_core` and searches `rust/target/release`;
  `NimbleCommanderCommon` gets `rust/include` on its header search path (that is where
  `Core/RustCore.mm` is compiled).
- `Core/RustCore.{h,mm}` is the only C++ code that includes `nc_core.h`; it throws if the linked
  library reports an ABI version it doesn't know.
- At startup, with `NC_PERF_LOG=1`, the app prints a smoke-test line:

```
[rust] nc_core abi=1 ping=42 glob=1
```

## What is implemented in Rust

| Function | Notes |
|---|---|
| `nc_core_abi_version`, `nc_core_ping` | smoke test |
| `nc_core_glob_match` | whole-name glob matcher (`*`, `?`), case sensitivity optional |
| `nc_core_search_native` | parallel (scoped-thread) BFS over the native filesystem with a glob filter, callbacks per match, cancellation via a shared flag, and counters (files/dirs/matches) |

The search is deliberately *not* wired into `SearchForFiles` yet: that class goes through the VFS
abstraction (archives, SFTP, WebDAV), and only the native filesystem fits the Rust fast path. The
next slice is to use the Rust walker for native hosts behind a config flag and to differential-test
it against the existing C++ walker (the filters and the callback contract are the hard part).

## Testing

- `cargo test` — 8 tests: the glob matcher, argument validation, a real search over a temporary
  tree, cancellation, and the ping.
- The app's startup smoke line proves the static link and the ABI handshake at runtime.

## Caveats

- Only the `NimbleCommander-Unsigned` target was wired up; the MAS/NonMAS targets would need the
  same two build settings and the script phase.
- `panic = "abort"` is *not* used: the `catch_unwind` guards require the unwinding runtime to stay
  in the picture.
