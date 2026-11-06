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

## The `RustFileSearch` adapter (app layer)

`Source/NimbleCommander/NimbleCommander/Core/RustFileSearch.{h,mm}` wraps `nc_core_search_native`
and mirrors the parts of `nc::vfs::SearchForFiles` the search UI uses (name/size filters,
files-vs-dirs, recursion, a per-hit callback, a finish callback, cancellation). It lives in the app
layer on purpose: the VFS library is used by many targets and should not grow a link-time dependency
on the Rust archive; `SearchForFiles` stays the implementation for archives, network hosts, content
filters and regular expressions.

Two findings from writing it:

1. **The callbacks arrive from many threads.** The Rust walker has N workers, so the C ABI callback
   fires from all of them at once. Passing those straight through corrupts any ordinary
   `std::vector` in the receiver (the first differential test aborted with SIGABRT in a worker
   thread for exactly this reason). The adapter serialises them with a mutex, which restores the
   contract `SearchForFiles` gives its callers.
2. **The C ABI speaks paths relative to the root**, while the C++ callers work with the absolute
   directory plus the file name - the adapter stitches those back together.

## Differential test and benchmark

`NimbleCommanderUT` now contains `RustFileSearch_UT.mm`:

- `finds the same files as the C++ search` runs both implementations over a temporary tree for the
  masks \`\` (everything), `*.txt`, `*.md` and `f*`, and compares the hit sets;
- `respects the size filter`, `rejects masks it cannot handle` (`*.txt,*.md`, non-ASCII) and
  `cancellation stops the walk` cover the rest of the adapter's contract;
- `benchmark against the C++ walker` prints a comparable pair of numbers (and asserts that both
  find the same 5000 files).

Measured in that benchmark (5000 files in 20 directories, Debug build of the test bundle):

```
[perf] rust_search cpp=300728us rust=14319us ratio=21.00
```

i.e. the Rust walker is **~21x** faster than the C++ VFS walker for this workload. The C++ side
walks through the VFS abstraction with per-entry virtual calls and a serial queue; the Rust side
uses `read_dir` directly with N workers. Part of the gap is the abstraction, not the language - the
honest framing is "a specialised native fast path" rather than "Rust is 21x faster".

## Not done yet

- The search UI (`FindFilesSheetController`) still always uses `SearchForFiles`. Wiring it to
  `RustFileSearch` for native hosts (with a config switch and a fallback for everything else) is the
  next step, and is the point where the user-visible speedup appears.
- The MAS/NonMAS targets still need the two build settings and the script phase.


## 内容搜索（第三个切片）

`nc_core_search_content` 在本地文件树里并行搜索文件内容：

- 输入是原始字节（通常是 UTF-8 文本）+ 选项（大小写不敏感、整词匹配）+ 文件大小上限；
- 遍历用与文件名搜索相同的并行 BFS，每个正则文件整体读入后匹配（`find_bytes`：先按首字节扫描，
  再做整段比较；大小写不敏感按 ASCII 折叠；整词匹配检查前后字节是否字母数字）；
- 命中通过回调上报（相对路径 + 偏移 + 长度），统计 files_scanned / files_skipped / matches。

C++ 适配层 `Core/RustContentSearch.{h,mm}` 把相对路径拼成绝对目录 + 文件名，并串行化回调
（Rust 侧有多个 worker，和文件名搜索一样）。

差分测试（`RustContentSearch_UT.mm`）：同一棵临时树分别用 `SearchForFiles`+`SearchInFile`（C++）
和 Rust 实现搜索 "needle"，逐条比较文件名与偏移，覆盖大小写敏感/不敏感、文件大小上限。

基准（2,000 个 4 KB 文件，其中 200 个包含目标文本）：

```
[perf] rust_content cpp=381370us rust=31786us ratio=12.00
```

即约 12 倍。差距来自两处：C++ 侧每个文件都要走 VFS（建 file → FileWindow → CFString 搜索），
Rust 侧直接 `read` + 字节比较。注意语义边界：Rust 版只覆盖 UTF-8/ASCII 与“首个命中”；
非 UTF-8 编码、正则、二进制/十六进制搜索仍然由 C++ 的 `SearchInFile` 负责。

尚未接线："查找文件"面板仍然只走 C++ 实现。把 `RustFileSearch`（文件名，21×）与
`RustContentSearch`（内容，12×）按条件接进 `FindFilesSheetController` 是下一步。

