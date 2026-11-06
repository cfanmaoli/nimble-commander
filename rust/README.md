# The Rust core

This is the Rust part of the app: a narrow, `extern "C"` library with no third-party dependencies
that the C++ code links statically (`libnc_core.a`).

The plan behind it is in `nc-rewrite-eval/Nimble-Commander-Fork-Swift-Rust-重构可行性评估.md`
(and its `research/` reports). Its recommendation is what this directory follows: **no big-bang
rewrite**, only read-only, measurable slices behind a C ABI, with the C++ implementation kept as an
oracle and as the fallback.

## Layout

| File | Purpose |
|---|---|
| `nc_core/src/lib.rs` | the library itself |
| `include/nc_core.h` | the C ABI, hand-written on purpose (see the spike report: cbindgen cannot produce a usable header for opaque handles) |
| `build.sh` | builds `target/release/libnc_core.a` |
| `rust-toolchain.toml` | pins the toolchain to stable |

## Building

```bash
rust/build.sh          # release static library, used by the Xcode build
cd rust && cargo test  # the unit tests
```

The Xcode project runs `build.sh` from a "Build Rust core" phase before compiling and links the
result with `-lnc_core` (`NimbleCommander-Unsigned` target). If `cargo` is not on `PATH`, the script
falls back to the isolated toolchain of the rewrite evaluation
(`nc-rewrite-eval/.toolchain`); set `NC_RUST_TOOLCHAIN` to override.

## What is migrated so far

| Slice | State |
|---|---|
| C ABI + build integration + smoke test (`nc_core_ping`, `nc_core_abi_version`, startup check) | done |
| `nc_core_search_native` — parallel native-filesystem filename search | done in Rust, **not wired into the app yet** (next step: `SearchForFiles` uses it for native hosts behind a config switch, with the C++ walker as the oracle) |
| `nc_core_glob_match` — glob matcher used by the search | done, unit-tested |

## Rules of the boundary

- Everything crossing the ABI is C-compatible and owned by the caller: the caller keeps the
  strings, the callback, its context and the cancel flag alive for the duration of a call.
- Every entry point is wrapped in `catch_unwind`, so a Rust panic becomes `NC_CORE_ERR_PANIC`
  instead of aborting the process inside a C++ frame.
- No Rust type is exposed by value; no `#[repr(C)]` struct is ever given out as an opaque handle.
