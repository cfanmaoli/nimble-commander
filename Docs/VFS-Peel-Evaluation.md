# 能否剥离 VFS 层？—— 评估

日期：2026-11-06。对象：`nimble-commander`（evil 分支）的 `Source/VFS` 抽象层。
起因：当时用 Rust 写的并行搜索比走 VFS 的 C++ 搜索快 21 倍，于是要评估"能不能把 VFS 层剥掉"。

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
| 并行 walker（readdir + 8 线程） | **14.3 ms** | 2.9 µs |
| 加速比 | **21×** | |

### 2.3 平铺扫描：1.6M 条目的真实成本

`/Volumes/TiPro9000/deepseek`：203,839 个目录、1,637,730 个条目。

| 实现 | 时间 | 备注 |
|---|---:|---|
| 现有平铺（VFS 串行逐目录 + 每目录 getattrlistbulk） | **14.5 s** | 内存峰值 644.8 MB |
| 并行 walker，8 线程，**不带属性**（readdir） | 2.33 s | 无法填大小/日期列 |
| 并行 walker，8 线程，**每条目 metadata**（stat） | 11.2 s | 只比 C++ 快 1.3× |
| 并行 walker，1 线程，每条目 metadata | 14.0 s | |

**解读**：21× 在"搜索"上成立，是因为搜索只需要名字；一旦每条目都要属性，
"逐条 `stat`"比"bulk 取属性"更贵，速度快不起来。平铺视图真正的加速点不是换语言，而是
**把 20 万个目录的枚举并行起来，同时仍用 getattrlistbulk 批量取属性**——这是可以做到的，
直接用 `getattrlistbulk` 批量取属性并把目录枚举并行化即可，预计能从 14.5 s 降到 3–5 s 量级。

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
  搜索已完成（`ParallelFileSearch` / `ParallelContentSearch`，差分测试全过）；平铺扫描已按同样方式完成。
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
   a. 平铺扫描（直接 `getattrlistbulk` + 并行目录枚举）——已完成；
   b. 文件夹大小计算（递归 + 并行）——同类问题，用户感知强；
   c. 把 `ParallelFileSearch` / `ParallelContentSearch` 接进"查找文件"面板（差分测试已就绪）。
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

## 6. 后续：把平铺扫描并行化之后（实测更新）

按 §5 的建议先做了“不换语言、先并行”的版本，结果值得记录，因为它修正了 §2.3 的推断。

改动内容：

1. `BuildFlatListing` 改成按层同步的并行 BFS：每层里的目录用 N 个线程并行取（`flatScanThreads`，
   默认 0 = 机器决定，封顶 8；可显式设到 32），条目回填仍然串行，保证预算记账与结果确定性；
2. 平铺扫描请求 `F_NoDotDot`——平铺本来就不显示 `..`，但以前每个目录都多付一次 dot-dot 的属性遍历；
3. `Fetching::ReadDirAttributesBulk` 的 1 MiB 枚举缓冲改成 thread_local 复用；以前 20 万个目录
   就要分配/清零 20 万次 1 MiB，这一项在单线程下就值 2.6 s。

实测（1,637,743 条目 / 203,839 目录，同一台机器）：

```
1 线程： took=12045ms scan=10976ms compose=1046ms fetch=10916ms fold=15ms
8 线程： took=9655ms  scan=8598ms  compose=1033ms fetch=8535ms  fold=14ms
```

- 相比改动前的 14.5 s，单线程 12.0 s（-17%，来自缓冲复用与 dot-dot），8 线程 9.7 s（-33%）；
- 并行只带来 1.25 倍，不是预期的 3–5 倍。原因从采样能看清：热点仍然在
  `FetchDirectoryListingImpl` → `ListingInput` → `Listing::Build`，也就是每个目录都在构造一个
  完整的 VFSListing（203,839 个），这部分是 CPU 与分配器的工作，而且每层还要 join/重新起线程；
- `fold`（串行回填）只有 15 ms，`compose`（最后合成大 listing）约 1.05 s，都不是瓶颈。

结论修正：平铺的瓶颈不是“目录枚举不并行”，而是“每个目录都构造一个中间 listing”。要真正把 9.7 s
降到 2–3 s，需要一次列式批量枚举（Rust 或 C++ 都行）：遍历时直接产出最终的 `ListingInput`，
不构造中间 `VFSListing`。这正好是 §3 方案 C 的前置条件，也是下一步该做的事。


## 7. 列式批量枚举（Rust）——落地版

§6 的结论是“每个目录构造一个中间 listing”才是平铺的瓶颈。这一步把枚举直接做成列式。

Rust 侧（`rust/nc_core`，新增 `nc_core_scan_flat`）：

- 直接调 `getattrlistbulk()`（FFI，属性集与 C++ 侧一致），按目录产出列式批次（`nc_flat_batch`：
  名字、长度、类型、模式、大小、四个时间、inode、uid/gid/flags）；
- 按层并行：每层的目录由 N 个线程取，回调从多个线程进入；
- 统计 files / dirs / entries / directories_scanned，取消标志与现有 ABI 一致。

C++ 侧（`Core/FlatListingBuilder.{h,mm}`）：

- 平铺构建从 `PanelController` 抽出来，变成 `nc::core::BuildFlatListingVFS(...)`（原实现，作为
  oracle 与回退）和 `nc::core::BuildFlatListingRust(...)`；
- Rust 版把批次直接写进一个 `ListingInput`，最后只调用一次 `VFSListing::Build`，中间没有任何
  `VFSListing`；
- 非 native 主机（归档/网络）自动回落到 VFS 实现；
- 配置 `filePanel.general.flatScanStrategy`（`columnar` 默认 / `composed`）与 `flatScanThreads`。

实测（同一棵树，1,638,003 条目 / 203,839 目录）：

| 策略 | 总耗时 | scan | compose |
|---|---:|---:|---:|
| composed（8 线程） | 9,987 ms | 8,886 ms | 1,077 ms |
| columnar（8 线程） | 5,755 ms | 5,599 ms | 156 ms |

即 1.73 倍，且两边条目数、目录数完全一致。compose 从 1.08 s 降到 0.16 s，因为它不再是
“合成 20 万个 listing”，而是一次 Build。

差分测试（`NimbleCommanderUT` / `FlatListingBuilder_UT.mm`）：同一棵临时树分别用两种策略构建
平铺 listing，逐条比较（路径、类型、是否目录、大小、修改时间），并覆盖条目预算截断与非 native 主机
的回落。写这个测试时发现并修掉了两个真实 bug：Rust 版一度把所有条目的父目录都写成最后扫描到的
那个目录（`ListingInput::directories/hosts` 没有 reset 成 dense），以及目录大小语义与 VFS 不一致
（应为 UINT64_MAX 而不是“没有大小”）。

仍未解决：5.6 s 的扫描里，`getattrlistbulk` 的属性抓取占大头（4 线程与 8 线程一样快，说明这块
外置盘的元数据吞吐已经饱和）。要再往下压，只能减少每次请求的属性，那是下一步的取舍。



## 8. 结论：C++ 实现同一策略，Rust 分支已删除

第 7 节的列式枚举最早是用 Rust 写的（`nc_core_scan_flat`）。后来判断：**这几次提速来自算法与并行，
与语言无关**，而 Rust 带来的是两条工具链、两套测试框架、一层手写 C ABI 与持续的语义对齐成本
（构建机上 cargo 还要指向一个硬编码路径）。于是把三个切片都改成了 C++，Rust 目录与全部相关代码已删除：

| 切片 | C++ 实现位置 | 实测 |
|---|---|---|
| 平铺列式枚举 | `Source/VFS/source/Native/Columnar.cpp`（复用 `Fetching::ReadDirAttributesBulk`）| 5,832 ms vs 逐目录 10,136 ms（1.74×）|
| 文件名并行搜索 | `Core/ParallelFileSearch.{h,mm}`（复用 `utility::FileMask`）| 25.4× vs VFS 逐条回调 |
| 内容并行搜索 | `Core/ParallelContentSearch.{h,mm}`（`memchr` + 逐文件读）| 8.7× |

两者行为一致性仍由差分测试保证（`FlatListingBuilder_UT`、`ParallelFileSearch_UT`、
`ParallelContentSearch_UT`），平铺策略开关保留：`filePanel.general.flatScanStrategy` = `columnar`（默认）/ `composed`。

### 8.1 接进“查找文件”面板

`FindFilesSheetController` 现在按条件在两个实现之间分派（`filePanel.general.parallelSearch`，默认开）：

- 走并行引擎：本地文件系统、未勾选“在压缩包中查找”、内容查询是 UTF-8 且没有“不包含”，
  且（有内容查询时）没有设大小过滤；
- 其余全部回落 `SearchForFiles`（归档、网络主机、非 UTF-8 编码、大小+内容组合）。

两条路径共用同一套 found / finish / “正在查找” 回调，表格、面板化、显示、往返导航都不变。
分派时打印一行便于验证：

```
[perf] findfiles engine=parallel content=0 mask=*
[perf] findfiles engine=parallel content=1 mask=*
```

实测（UI 手工验证）：在 `Source/` 下用掩码 `*PanelController*` 搜到 10 项、用内容
`PanelController` 搜到 132 项，日志确认两种查询都走了并行引擎。


## 9. 修：`/Users/lim` 平铺一直“加载中”

现象：在 `/Users/lim` 上开平铺，面板一直卡在加载。

排查（先给列式枚举加了 `[perf] flat slowdir`，超过 200 ms 的目录打一行）：

```
[perf] flat slowdir 1874ms /Users/lim/Library/CloudStorage/坚果云-.../实验/抗体 +药物/.../MetaData/
[perf] flat slowdir 1814ms /Users/lim/Library/CloudStorage/坚果云-.../动物实验/第二批/...
... 90 秒内 1380 个这样的目录 ...
```

结论：`~/Library/CloudStorage` 是 File Provider（坚果云）域，**每个目录的枚举 1.5–1.9 s**（网络往返）。
`/Users/lim` 的平铺会走进去，几千个目录 × 1.7 s ÷ 8 线程 = 十几分钟起步；首次访问还要把占位符
materialize，所以看起来就是“永远加载”。（composed 策略同样会卡——这是路径本身的性质，不是列式策略的回归。）

修复：给平铺扫描加**墙钟预算** `filePanel.general.flatViewMaxSeconds`（默认 30 s，0 = 不限）：

- 两种策略都在级别循环与单目录循环里检查预算，超时就把已有结果装上去并标记 `timed_out`；
- 面板弹出专门的提示："扫描耗时过长，因此只显示了前 N 项……可以在 filePanel.general.flatViewMaxSeconds 中提高时间上限"
  （en/ru/zh-Hans 三条）；
- 日志里 `timed_out` 一并输出，便于诊断。

验证：

| 场景 | 结果 |
|---|---|
| 预算 1 s（`flatViewMaxSeconds=1`） | `items=8045 dirs=4545 truncated=1 took=1053ms`，显示部分结果并弹提示 |
| 预算默认 30 s（元数据已被系统缓存后） | `items=342397 dirs=47925 took=2372ms`，与 `find /Users/lim -xdev` 的 342,400 一致 |

也就是说：首次冷访问会被 30 s 预算截断并给出解释，之后的访问 2.4 s 就能扫完。


### 9.1 改成跳过云目录

时间预算只是兜底；真正该做的是**不进入云同步目录**。现在：

- 开关 `filePanel.general.flatViewSkipCloudStorage`（默认 **true**）；
- 跳过的两个前缀：`<home>/Library/CloudStorage/`（File Provider 域，如坚果云、OneDrive、Google Drive）
  与 `<home>/Library/Mobile Documents/`（iCloud Drive）；
- 跳过发生在**收集子目录**时，两种策略（columnar / composed）都生效，条目本身不进结果；
- 如果平铺的根就在这两个前缀里（用户明确要看），则不跳过——此时只有 30 s 预算兜底；
- 由于“跳过”是静默少内容，第一次跳过的那个启动会弹一次说明（en/ru/zh-Hans），之后只记日志，
  不会每次开平铺都弹。

实测 `/Users/lim`（默认配置，8 线程）：

```
[perf] flat root=/Users/lim/ items=280029 dirs=38873 skipped=2 truncated=0 listing=1 took=2211ms ... strategy=columnar
```

即：2 个云目录被跳过，62k 个云里的条目不再进入平铺，2.2 s 完成，且不再需要靠时间预算截断。
测试 `FlatListingBuilder skips the requested cloud directories` 覆盖了跳过行为，并断言两种策略结果一致。

