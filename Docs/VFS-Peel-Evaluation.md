# 能否剥离 VFS 层？—— 评估

日期：2026-11-06。对象：`nimble-commander`（evil 分支）的 `Source/VFS` 抽象层。
起因：Rust 版并行搜索比走 VFS 的 C++ 搜索快 21 倍（见 `Docs/Rust.md`），于是要评估"能不能把 VFS 层剥掉"。

## 0. 结论

1. **不建议剥离**：VFS 不是一个可选的性能包装，它是"归档 / FTP / SFTP / WebDAV / 进程"这些功能
   赖以存在的地方，而列表热路径的性能瓶颈**不在抽象层**——实测抽象开销约等于 0（见 §2.1）。
2. **该做的是"给热路径开专用通道"**：搜索已经这么做了（21×）；接下来是**平铺扫描**和**文件夹大小计算**，
   它们的瓶颈是"逐目录串行 + 每条目回调"，不是 VFS 本身。
3. 如果将来要把 native 后端内部换成 Rust（评估报告里的 P3），**前置条件**是给 `Host` 增加
   "批量枚举"接口；只换实现、保留逐条回调的契约，收益会像平铺扫描那样被 per-entry 开销吃掉（见 §2.3）。

## 1. 现状数据

### 1.1 模块与后端（`Source/VFS`）

| 项 | 数值 |
|---|---:|
| 代码行数 / 文件数 | **27,425 行 / 152 个文件** |
| 接口：`Host.h` / `Listing.h` | 400 行 / 400 行 |
| Native 后端 | 2,483 行 |
| ArcLA（libarchive 归档） | 2,472 行 |
| ArcLARaw（裸归档） | 421 行 |
| NetFTP | 2,374 行 |
| NetSFTP | 1,959 行 |
| NetWebDAV | 2,912 行 |
| PS（进程列表） | 890 行 |

### 1.2 使用面（除 VFS 自身外，引用 `VFSHostPtr`/`VFSListingPtr`/`VFSListingItem`/`vfs::Host` 的文件数）

| 模块 | 文件数 |
|---|---:|
| NimbleCommander（UI/状态/面板） | 92 |
| Operations（复制/移动/删除/属性） | 43 |
| Panel（列表模型/过滤/排序） | 17 |
| Viewer | 7 |
| VFSIcon | 7 |
| Term / Config / Utility | 0 |

类型级：`VFSListingItem` 出现在 105 个文件、`VFSHostPtr` 63 个、`VFSListingPtr` 27 个。
也就是说 **VFS 是贯穿 UI/操作/查看器的地基**，不是可插拔的边缘模块。

## 2. 性能实测（同一台机器，同一份数据）

### 2.1 列表热路径：抽象层不是瓶颈

1,000,001 条目的目录：

| 测量 | 时间 |
|---|---:|
| 裸 `getattrlistbulk`（属性集与 App 一致，1 MiB 缓冲） | **2.6 s** |
| 裸 `readdir`（只要名字） | 0.61 s |
| App 经 VFS 的 `FetchDirectoryListing`（含 listing 构建 11 ms） | **2.2–2.8 s** |

**结论**：VFS 的封装开销在测量噪声内（≈0），这一层去掉也快不了——内核取属性本身就是 2.6 s。

### 2.2 walk 路径：抽象层确实是瓶颈

5,000 个文件 / 20 个目录的搜索（`NimbleCommanderUT` 的差分基准）：

| 实现 | 时间 | 每条目 |
|---|---:|---:|
| C++ `SearchForFiles`（经 VFS 逐条回调） | **300.7 ms** | 60 µs |
| Rust `nc_core_search_native`（readdir + 8 线程） | **14.3 ms** | 2.9 µs |
| 加速比 | **21×** | |

### 2.3 平铺扫描：1.6M 条目的真实成本

`/Volumes/TiPro9000/deepseek`：203,839 个目录、1,637,730 个条目。

| 实现 | 时间 | 备注 |
|---|---:|---|
| 现有平铺（VFS 串行逐目录 + 每目录 getattrlistbulk） | **14.5 s** | 内存峰值 644.8 MB |
| Rust walker，8 线程，**不带属性**（readdir） | 2.33 s | 无法填大小/日期列 |
| Rust walker，8 线程，**每条目 metadata**（stat） | 11.2 s | 只比 C++ 快 1.3× |
| Rust walker，1 线程，每条目 metadata | 14.0 s | |

**解读**：Rust 的 21× 在"搜索"上成立，是因为搜索只需要名字；一旦每条目都要属性，
"逐条 `stat`"比"bulk 取属性"更贵，速度快不起来。平铺视图真正的加速点不是换语言，而是
**把 20 万个目录的枚举并行起来，同时仍用 getattrlistbulk 批量取属性**——这是可以做到的，
用 Rust 调 `getattrlistbulk` 的 FFI 即可，预计能从 14.5 s 降到 3–5 s 量级（需实测）。

## 3. "剥离"的三种含义、成本与收益

### 方案 A：彻底剥离（只支持本地文件系统）

- **做法**：删掉 `Host`/`Listing` 抽象，面板与操作直接对 `/Volumes` 上的 POSIX/APFS 操作。
- **代价**：归档（ArcLA/ArcLARaw）、FTP/SFTP/WebDAV、进程列表全部消失；Operations（43 个文件）、
  Panel（17）、UI（92）里所有 `VFSListingItem`/`VFSHostPtr` 的用法都要重写；Viewer/Term 里
  依赖主机抽象的部分也要改。
- **收益**：列表路径 **≈0**（§2.1）；walk 路径最多到 21×（§2.2）。
- **工期**：数月起步，且不可回退——等于把这个 fork 变回"只认本地盘"的另一个软件。
- **结论**：**不做**。用"删掉 27k 行地基"换一个已经能用专用通道拿到的加速，性价比是负的。

### 方案 B：保留接口，给热路径开专用通道（当前路线）

- **做法**：对本地主机、无归档/内容过滤的场景，绕过 VFS 的逐条抽象，直接用"原生 + 并行"实现。
  搜索已完成（`RustFileSearch`，差分测试全过）；平铺扫描、文件夹大小计算可按同样方式做。
- **收益**：搜索 21×（已验证）；平铺 14.5 s → 预计 3–5 s（需实测）；文件夹大小计算同类。
- **风险**：低——VFS 契约不变，其它场景全走原路径；每个切片都有差分测试与回退开关。
- **工期**：每个切片 1–3 天（含测试与基准）。

### 方案 C：保留接口，把 Native 后端内部换成 Rust（评估报告 P3）

- **做法**：`NativeHost` 的实现内部改用 Rust，对外仍是 `Host` 的接口。
- **收益**：所有"经 VFS 的本地操作"都能吃到 Rust 的并行与零拷贝，而不仅是搜索/平铺。
- **前提**：**必须新增批量接口**（例如"一次返回整目录的列式属性"），否则每个条目仍要跨一次
  C ABI + 一次回调，平铺扫描那种场景的收益会被吃掉（§2.3 的 11.2 s vs 14.5 s 就是证据）。
- **风险**：中——要动 VFS 的核心路径，同时得保住 765 个用例与归档/网络后端的行为。
- **工期**：3–6 个月（评估报告口径）。

## 4. 建议

1. **不做 A**；把这条写进文档，避免以后重复讨论。
2. **继续 B**，顺序建议：
   a. 平铺扫描（Rust 调 `getattrlistbulk` + 并行目录）——当前 14.5 s，收益最直观；
   b. 文件夹大小计算（递归 + 并行）——同类问题，用户感知强；
   c. 把 `RustFileSearch` 接进"查找文件"面板（差分测试已就绪）。
3. **C 只在 B 做完且仍不够快时再评估**，并且第一步先设计"列式批量枚举"接口，而不是直接换实现。

## 5. 复现命令

```bash
# 裸枚举基线
cc -O2 -o /tmp/bulk2 ncbench/bulk2.c && /tmp/bulk2 <dir> full 1048576
cc -O2 -o /tmp/rd    ncbench/rd.c    && /tmp/rd <dir>
# Rust walker（两模式）
clang -O2 -I rust/include -o /tmp/walkbench ncbench/walkbench.c rust/target/release/libnc_core.a
/tmp/walkbench <dir>        # 带每条目 metadata
/tmp/walkbench <dir> n      # 纯枚举（无回调）
# App 侧
scripts/perf/open_benchmark.sh <dir>     # 列表路径
# 平铺扫描：Config.json 里把 flatViewMaxItems 调大后开平铺，看
#   [perf] flat root=... items=... took=...ms
```
