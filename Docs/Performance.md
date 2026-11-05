# 百万级文件性能评估

> 评估对象：Nimble Commander-Fork（branch `evil`，commit 9669c1a74）
> 评估日期：2026-11-06
> 环境：macOS 27.2，30 核 Apple Silicon，外置 NVMe（APFS，TiPro9000），1.5 TB 空闲

## 0. 结论速览

渲染不是瓶颈。面板是 view-based NSTableView，只物化可见的 30–50 行，图标按可见区懒加载，
1M 行的滚动/绘制本身没有问题。**真正的成本全部在"数据面"**：枚举、建模、排序、刷新策略。

| 场景（实测） | CPU | 墙钟 | 峰值 RSS |
|---|---|---|---|
| 打开 1,000,000 个小文件目录 | 5.66–6.08 s | 4.5–5.7 s | 483–490 MB |
| 目录内**发生一次**外部改动（新建 1 个文件）| 5.1–5.3 s | 4.4–5.5 s | 峰值 ~640 MB |
| 打开 200,000 个**子目录**（默认配置）| 8.7 / 16.7 s（两次）| 10.2 s | 210–296 MB |
| 内核底线：纯 `readdir` 枚举 1M 项 | 0.60 s | — | — |
| 内核底线：`getattrlistbulk`（当前属性集）1M 项 | 2.0–2.2 s | — | — |

四个结论：

1. **没有任何增量更新机制**：FSEvents 只被当作"目录变了"的信号，随后整目录重新枚举 + 整个
   panel 重新排序。1M 目录里每建/删一个文件，都要付 5 秒 + 双份内存
   （`PanelController.mm:723-741` → `:508` → `PanelData.mm:146-230`）。
2. **建模在主线程上同步做**：`Model::Load/ReLoad` 里的两次全量排序 + 统计 + 索引重建，
   主线程 `exec_group.Wait()` 空等（`PanelData.mm:126-128`）；刷新路径干脆完全串行
   （`PanelData.mm:227-229`）。期间窗口无响应。
3. **每个文件名都预先建一个 CFString**：`Listing::Build` 里 1M 次 `CFStringCreateWithBytes`
   （`Listing.cpp:386-416`）。heap 实测 `1,009,342` 个 CFString 对象，仅这一项就是
   32.5 MB + 1M 个 32B 的对象头。
4. **目录密集的场景比文件密集更糟**：200k 子目录要 8.7–16.7 s，而 1M 文件只要 5.7 s。
   `sample` 显示 `11,622 / 12,000` 个采样（97%）落在
   `DisplayNamesCache::DisplayName` → `[NSFileManager displayNameAtPath:]`
   （`DisplayNamesCache.mm:156-208`）——即"显示本地化文件名"这个默认开启的功能
   （`Config.json:71`），每个目录一次 LaunchServices 查询 + 一次 stat + 一次
   `decomposedStringWithCanonicalMapping`，而且外面还套了一把全局读写自旋锁。

目标建议：**首屏 <100 ms、1M 目录全量就绪 <2 s、目录变动可见更新 <50 ms、常驻内存 ≤250 MB/1M**。
按下面的 P0 三项做完，前三个指标都能达到。

---

## 1. 测试方法与数据

- 数据集：`/Volumes/TiPro9000/deepseek/ncbench/m1`，100 万个 13 字符名小文件
  （`f_0000000.txt` …），无扩展属性；另一组为 20 万个空子目录。
- 计时：`ps -o time=` 读进程累计 CPU，0.2 s 采样一次直到累计值 10 次不变（settle）；
  RSS 同一循环采集；`sample 1ms` 做函数级归因；`heap` 看分配构成。
- 内核底线用独立 C 程序测（`ncbench/rd.c`、`bulk2.c`），属性集与应用一致。
- 排序微基准用独立 ObjC++ 程序（`ncbench/sortcheck.mm`），1M 个 CFString、随机顺序。

微基准（单线程，1M 项，随机序）：

| 比较方式 | 耗时 |
|---|---|
| `CFStringCompare(kCFCompareCaseInsensitive)`（当前默认） | 0.40 s |
| `localizedStandardCompare`（"自然排序"选项） | 1.29 s |
| 整数/字节比较 | 0.02 s |
| 1M 次 `CFStringCreateWithBytes` | 41 ms |
| 1M 次 `getattrlistbulk` 枚举（64 KB 缓冲，2809 次调用） | 2.09 s |
| 同上，1 MB 缓冲（176 次调用） | 1.97 s |
| 同上，缩减属性集（name/objtype/size/fileid） | 2.09 s（**无收益**） |
| 同上，只要 name 的 `getattrlistbulk` | 6.2–9.4 s（内核慢路径，**别用**） |
| 纯 `readdir` | 0.60 s |

两个反直觉但重要的结论：

- **裁剪属性位图不省时间**：枚举 1M 项的成本主要不在取属性，而在 APFS 目录 B-tree 遍历 +
  name 拷贝；属性位图砍掉一半，时间一分不省。
- **"只要名字"的 `getattrlistbulk` 反而慢 3–4 倍**（内核走另一条路径）。想要"快速拿到
  名字"，唯一快的方式是 `readdir`（0.6 s），不是缩小属性集。

---

## 2. 时间都去哪了

以 1M 文件目录的冷开（5.7 s CPU）为例，按 `sample` 与代码结构估算：

| 阶段 | 估算 | 主要证据 |
|---|---|---|
| `getattrlistbulk` 枚举 + 逐项填充 13 个数组 | 2.0–2.6 s | `Host.cpp:107-184`、`Fetching.cpp:278-419` |
| `Listing::Build`：Validate + Compress + 1M CFString + 扩展名扫描 | 0.6–1.0 s | `Listing.cpp:134-165, 386-416` |
| `Model::Load`：`DoRawSort` + `DoSortWithHardFiltering` + 索引 + 统计（主线程阻塞）| 1.0–1.5 s | `PanelData.mm:105-132, 400-405, 775-843` |
| 表格 `insertRows`(1M) + 图标表扫描 + 首帧 | 0.5–1.0 s | `PanelListView.mm:576-630`、`IconRepositoryCleaner.mm:22-29` |

刷新（FSEvents）比冷开还贵（5.1–5.3 s），因为 `Model::ReLoad` 又额外做了一遍
raw-name 排序 + O(n) 合并，再串行重排一次（`PanelData.mm:151-229`），而冷开时至少
两个排序是并发跑的。

200k 子目录：`sample` 归因非常干净——97% 采样在
`Host.cpp:146-153` → `DisplayNamesCache::DisplayName` → `IO::DisplayNameAtPath`。
即 `F_LoadDisplayNames` 对**每个目录**都做一次 `stat` + `[NSFileManager displayNameAtPath:]`
+ 一次 Unicode 规范化，平均 ~60 µs/目录。

---

## 3. 优化清单

按"收益/风险"排序。每条给出现状证据、改法、预期收益。

### P0-1 增量刷新（收益最大，质变）

**现状**：`ObserveDirectoryChanges` 的回调只携带"目录变了"，代码丢掉路径信息后直接
`refreshPanel` → 整目录 `FetchDirectoryListing` → `Model::ReLoad` → 整表更新
（`PanelController.mm:723-741`、`:470-538`、`PanelData.mm:146-230`）。

**改法**：
- `FSEventsDirUpdate` 已经能给出变更路径列表（当前被聚合掉了），把它透传到 panel。
- 保留旧 `VFSListing` + 旧排序索引；对每个变更路径调用已有的
  `NativeHost::FetchSingleItemListing`（`Host.cpp:268`，只 stat 单条）得到新条目。
- 在 raw 索引里做插入/删除（名字向量本身有序时 O(log n + k)），再在已排序数组里做
  `equal_range` 定位 + 局部搬移（O(k + n) 但常数极小），或惰性合并。
- 表格用 `insertRowsAtIndexes/removeRowsAtIndexes` 只发 k 个索引，替换现在的
  全范围 `NSIndexSet`（`PanelListView.mm:622`）；k 很大时才回退 `reloadData`。
- 兜底：非路径类变更（卷挂载、.Trash 等）仍走全量。

**预期**：单文件变动 5.1 s → **10–50 ms**（两个数量级），且不再冻结 UI；峰值内存不再翻倍
（现在新旧两份 listing 同时存在，RSS 从 483 MB 冲到 640 MB）。
**风险**：中。diff 正确性、排序稳定性、光标/选择恢复都要测；工作量 1–2 周。

### P0-2 首屏优先 / 渐进式列举

**现状**：`Model::Load` 一次性完成"全部数据 + 排序 + 统计"之后才 `dataUpdated`，
在那之前一行都不画（`PanelData.mm:119-131`、`PanelController.mm:1014`）。冷开始终是白屏
（恢复窗口时甚至是同步加载，窗口要等 1M 载完才出现，`PanelController.mm:1040-1046`）。

**改法**：
- 枚举分块（比如每 4096 条）发布一次；先以"原始顺序快照"渲染表格 → 首屏立刻出现。
- 排序在后台线程完成后，带 generation 号原子替换索引数组；表格只重绘可见行——这条路
  现在的"点表头排序"已经在用（`PanelListView.mm:618` 只 refill 可用行视图），复用即可。
- 统计（`UpdateStatictics`）改成增量或在后台算，不阻塞首屏。

**预期**：1M 目录首屏 **<100 ms**（枚举前 2000 条约 4 ms），全量就绪仍 ~2–5 s 但用户可交互。
**风险**：中。需要 Model 支持"可追加 + 排序未就绪"状态，且要保证 selection/cursor 语义。

### P0-3 把排序/统计移出主线程

**现状**：`Model::Load` 在主线程用 `DispatchGroup{High}.Run(...)` 起两个排序任务后
`Wait()`（`PanelData.mm:125-128`）；`ReLoad` 更是完全串行（`:227-229`）。
排序期间主线程被占死。

**改法**：Load/ReLoad 整体改成后台任务，主线程只做最终 swap（配合 P0-2 的 generation 号）。
`UpdateStatictics` 用 diff 增量更新计数/字节数。

**预期**：1M 排序（0.4–1.3 s）期间界面可滚动；与 P0-2 一起把"卡死"变成"渐进"。
**风险**：低–中（需要明确并发边界，现在满屏 `dispatch_is_main_queue()` 断言）。

### P1-1 惰性 CFString

**现状**：`Listing::Build` → `BuildFilenames` 为**每个**条目建 CFString 并存指针
（`Listing.cpp:386-416`，`Listing.h:177`）。实测 1M 个 CFString = 32.5 MB 对象 +
8 MB 指针数组 + 1M 次 malloc 的碎片。

**改法**：`m_FilenamesCF` 做成按需填充的 `mutable` 数组（分块 + 原子指针发布），
只有真正显示/比较到的条目才建；排序若改用整数键（P1-2），大部分条目永远不需要 CFString。

**预期**：省掉 41 ms 的字符串构建、-50–60 MB 常驻内存、消除 1M 次分配带来的堆碎片。
**风险**：低（对象不可变，懒填充用双检即可）。

### P1-2 排序键 + 并行排序

**现状**：每次比较都走 `DisplayFilenameCF()`（稀疏容器查找）+ `CFStringCompare`
（`PanelDataEntriesComparator.cpp:16-31, 268-271`），1M 项排序 ~2000 万次比较。

**改法**：O(n) 预计算 64-bit 排序键（ASCII case-fold + 数字段解析；自然序用
`ucol_getSortKey` 生成 ICU 排序键），`pstld::sort` 只比整数；键相同时才回落到
`CFStringCompare` 保证稳定性。

**预期**：0.40 s → 0.05–0.10 s；自然排序 1.29 s → ~0.15 s。
**风险**：低–中（键语义必须与现有 comparator 逐字节等价，要有对拍测试）。

### P1-3 枚举本身：readdir 先行 + 属性按需

**现状**：一次 `getattrlistbulk` 取全部 15 个属性（`Fetching.cpp:264-277`），1M 项 2.0 s；
纯 `readdir` 只要 0.60 s。

**改法**（收益最大但改动最深）：
- 第一阶段 `readdir` 拿名字 + d_type（0.6 s），立刻可渲染、可按键名排序。
- 属性（size/mtime/uid…）按可见区 + 当前排序列惰性批量取；未取到的显示"…"。
- 用户按大小/时间排序时再触发全量属性补取（后台，带进度）。
- 顺带：枚举缓冲从 64 KB 提到 1 MB（2809 → 176 次系统调用，实测约 5%，零风险）。

**预期**：冷开 5.7 s → 2.5–3 s；配合 P0-2 首屏 <100 ms。
**风险**：中–高（属性语义、排序/过滤依赖全量属性；需要"未就绪"的 UI 状态）。

### P1-4 去掉重复排序 / 重复 O(n) 扫描

- `DoRawSort`（`PanelData.mm:400-405`）只为 `ReLoad` 合并服务，可以直接用
  `unordered_map<filename, raw_index>` 合并，省一次 O(n log n)。
- `IconRepositoryCleaner::SweepUnusedSlots` 每次 `dataUpdated` 扫全部 raw 条目
  （`IconRepositoryCleaner.mm:22-29`）→ 改成 slot 带 generation，O(已注册图标数)。
- `notifyLastColumnToRedraw` 逐行循环（`PanelListView.mm:945-952`）→ `setNeedsDisplay`。

**预期**：合计 -0.3–0.5 s/次，且每次刷新都省。
**风险**：低。

### P1-5 目录密集场景：本地化文件名

**现状**：`showLocalizedFilenames` 默认开（`Config.json:71`），每个**目录**一次
`stat` + `[NSFileManager displayNameAtPath:]` + `decomposedStringWithCanonicalMapping`，
外面还有全局读写锁（`DisplayNamesCache.mm:156-208`）。200k 子目录 → 97% 的时间花在这里。

**改法**（任一组合）：
- 只对可见行做显示名（懒加载），排序时用文件名；滚动到位再替换显示名。
- 大目录阈值：条目数 > N（如 50k）自动跳过显示名（或只对 30 个"已知会本地化"的目录名如
  `Desktop/Documents/Downloads` 做特殊处理）。
- 缓存从"每次启动冷"改成持久化（按 inode+dev）。

**预期**：200k 子目录 8.7–16.7 s → ~2.5 s（≈3–6×）。
**风险**：低（纯显示层）。

### P2 面向 1000 万项的结构性改造

1. **紧凑列式存储**：name arena（offset+len）+ 位域 type/flags + 8B size + 8B mtime，
   uid/gid/flags/atime 改为按需；~50 B/项 → 10M 约 500 MB（现在 ~480 B/项 ≈ 4.8 GB）。
2. **排序可中断 + 分段**：10M 并行排序 ~2–4 s，必须后台 + 渐进；按列排序时只排可见窗口
   （top-k 选择）也能满足首屏。
3. **视图层**：>1M 行时避免 `insertRows` 全量语义，改用 `noteNumberOfRowsChanged` 或
   自建虚拟化（NSDiffableDataSource 在百万级也不合适）。
4. **目录树并行**：flat view / 递归搜索按子目录并行枚举（现在 flat view 是单线程逐目录
   `FetchDirectoryListing` 再 `Compose`，`PanelController.mm:137-191`，重目录树会明显慢）。
5. **预算与可观测性**：内置"列举耗时/N 项"日志，超阈值自动降级（关显示名、关标签读取）。

### 顺带发现的缺陷（非性能，但影响正确性）

- `Fetching.cpp:47-49` 与 `:238-239`（Admin Mode 的逐条 `lstat` 路径）：
  `chg_time` 取的是 `st_mtimespec`、`acc_time` 取的是 `st_ctimespec`，二者互换；
  默认的 `getattrlistbulk` 路径没有这个问题。
- `Listing::IsDotDot`（`Listing.cpp:720-725`）直接读 `s[0..2]`，依赖 `std::string`
  末尾的 `'\0'` 才算安全——语义正确但很脆弱，改成一个 `size()==2 && ..` 判断更稳。
- `Listing::Count()` 返回 `unsigned`，上限 4.29G；扩展名偏移是 `uint16_t`，>255 字符名会错。
- 标签读取默认开启（`Config.json:251`）：带扩展属性的文件每条一次 `openat` +
  `flistxattr`（`Host.cpp:241-254`）。对"下载目录"这类文件，1M 项会额外增加可观系统调用。

---

## 4. 建议的落地顺序

**阶段 A（低风险，1–2 周）**：P1-4 + P1-1 + P1-2 + 枚举缓冲 1 MB。
预期：冷开 5.7 s → 4.5 s，内存 -60 MB，排序快 4×。

**阶段 B（2–4 周）**：P0-3 + P0-2（后台建模 + 首屏渐进）。
预期：首屏 <100 ms，界面不再卡死，用户感知发生质变。

**阶段 C（4–8 周）**：P0-1（FSEvents 增量 diff）+ P1-5。
预期：目录变动 5 s → 数十毫秒；200k 子目录 10 s → 2.5 s。

**阶段 D（长期）**：P1-3（惰性属性）+ P2（紧凑存储、10M 支持）。

验收指标（可直接写进 CI/手工 benchmark）：

| 指标 | 现在 | 目标 |
|---|---|---|
| 1M 目录首屏 | ~5 s | ≤100 ms |
| 1M 目录全量就绪 | 5.7 s | ≤2 s |
| 目录内单文件变动 → 可见更新 | 5.1 s | ≤50 ms |
| 200k 子目录打开 | 8.7–16.7 s | ≤2.5 s |
| 常驻内存 / 1M | 483 MB | ≤250 MB |
| 10M 目录 | 不可用 | 可打开、可滚动、变动 ≤200 ms |

---

## 5. 复现

基准脚本与数据都在 `/Volumes/TiPro9000/deepseek/ncbench/`：

- `gen.c` / `gen2.c`：生成 N 个文件 / 子目录 / 带 xattr 的文件
- `rd.c`：纯 `readdir` 基线
- `bulk2.c`：`getattrlistbulk` 各种属性集/缓冲的基线
- `sortcheck.mm`：1M 项三种 comparator 的排序微基准
- `measure*.sh`：应用级计时（CPU/RSS/settle），`sample*.txt`：函数级归因

注意：应用启动会恢复上一次的窗口状态，做 A/B 时要先删除
`~/Library/Application Support/Nimble Commander-Fork/State` 与
`~/Library/Saved Application State/info.filesmanager.Files.savedState`，
或按 `measure11.sh` 的做法用"路径互换"复用被恢复的目录。

---

## 6. 第一轮改动（已落地）

下面这些已经在 `evil` 分支的工作区里实现、编译并安装验证过（尚未提交）。

| 改动 | 文件 | 效果 |
|---|---|---|
| 枚举缓冲 64 KiB → 1 MiB | `VFS/source/Native/Fetching.cpp` | 1M 项的系统调用 2809 → 176 次 |
| 本地化显示名只对小/中目录做 | `VFS/source/Native/Host.cpp` | 每个目录省掉 ~60 µs 的 LaunchServices 查询（原先占目录密集场景 97% 的时间） |
| Brief 视图不再逐个测量 100 万个文件名 | `.../Brief/PanelBriefView.mm` | 1M 项 Brief：49.66 s → **7.89 s** CPU，1.23 GB → 0.80 GB；20 万子目录 Brief：10.86 s → **3.05 s** |
| 大批量行变更不再逐个 insert/remove | `.../List/PanelListView.mm` | 整体替换走 `noteNumberOfRowsChanged` / `reloadData` |
| 阶段计时埋点（`NC_PERF_LOG`） | Host / Listing / PanelData / PanelController | 随时可打印各阶段耗时 |

### 6.1 阶段分解（实测，1M 文件目录；fetch/build/model 与布局无关，ui 为默认 Brief 布局）

```
[perf] fetch   n=1000002 enum=2789.7ms epilogue=0.2ms build=56.6ms total=2846.5ms
[perf] build   n=1000002 validate=0.5ms compress=6.2ms move=1.8ms filenames=48.1ms
[perf] model   n=1000002 vd=3.6ms sorts=207.5ms softfilter=0.2ms stats=5.8ms
[perf] ui      n=1000002 modelLoad=217.2ms dataUpdated=37.2ms tail=78.7ms total=333.1ms
```

结论：**枚举（内核）占 82%**，其余加起来不到 20%。所以“把排序改快”最多只能吃掉 0.2 s；
真正的大头是 (a) 不要重复枚举（增量刷新），(b) 不要让用户等枚举（渐进式首屏）。

### 6.2 一个此前没发现的坑：Brief 视图

`sample` 显示 Brief 模式下 1M 目录有 30+ 秒 CPU 花在
`NCPanelBriefView calculateFilenamesWidths` → `TextWidthsCache::Widths` →
`CalculateWidthsOfStringsBulk`（把**所有**文件名拼成一个大字符串交给 CTFramesetter 量宽度）。
现在超过 20'000 项就只量前 20'000 个，其余用测到的最大值填充。

顺带修掉一个既有 bug：`dynamic_width_equal` 分支里的
`std::max_element(widths.begin(), widths.begin())` 应为 `end()`，之前等价于“取第一个条目的宽度”。

### 6.3 关于测量本身

`ps -o time` 的进程 CPU 时间对这类程序**不可靠**：并行排序用的线程池（`pstld`）在任务结束后
会自旋等待，把 CPU 时间抬高数秒，且随机器状态波动。做版本对比请用阶段计时（`NC_PERF_LOG=1`）
+ 墙钟 + 可交互时间，不要只看 `ps` 的累计 CPU。

### 6.4 还没做（下一轮）

1. **增量刷新**（P0-1）：FSEvents 能拿到变更路径，但 `VFSHost::ObserveDirectoryChanges` 的回调只有
   `void()`，需要扩成 `void(std::span<const std::string>)`，并让 `VFSListing` 支持“打补丁重建”。
   这是拿到 <50 ms 刷新的唯一路径。
2. **后台建模 + 渐进首屏**（P0-2/P0-3）：`Model::Load` 目前在主线程同步排序（0.2 s，但会冻结）。
3. **排序键**（P1-2）与**去重复排序**（P1-4）：排序只占 0.2 s，优先级下降。
4. **惰性属性**（P1-3）：枚举 2.8 s → 理论 0.7 s（readdir 0.6 s），但需要“属性未就绪”的 UI 状态。
5. **图标表清理**（每次 `dataUpdated` 扫全表）与**惰性 CFString**（约 -60 MB）。

---

## 7. 第二轮：路径级增量刷新（阶段 C）

### 7.1 做了什么

1. **FSEvents 现在带条目名**：事件流加上 `kFSEventStreamCreateFlagFileEvents`（原来只有目录级事件），
   回调里把「直接子项」的名字收集起来交给上层。
2. **VFS 新接口** `Host::ObserveDirectoryChangesWithPaths(path, void(std::span<const std::string>))`：
   默认实现退化成旧的 `void()` 版本（其它 host 不用改），`NativeHost` 覆盖它。
3. **列表打补丁** `ProducePatchedListing()`（PanelController.mm）：对变更路径做 `FetchSingleItemListing`
   （每条一次 `lstat`，微秒级），然后把「旧 listing 去掉被删/被改条目 + 新条目」重新拼成一个新的
   `VFSListing`。这里刻意不走 `VFSListing::Compose()`——Compose 用稀疏容器逐条插入，1M 项要上千万次哈希插入。
4. **模型增量应用** `Model::ApplyPatchedListing()`：保留所有存活条目的 volatile data（选择、图标、目录大小）、
   保留已排好的顺序，只做 O(n) 的索引重映射 + k 次二分插入；不再重排 100 万项。

### 7.2 实测（1M 文件目录，改一个文件）

```
[perf] incr    k=1 removed=1 appended=1 fetch=0.1ms  patch=154.2ms
[perf] incr.ui n=1000003 model=10.3ms view=131.8ms total=142.1ms
```

| | 改前 | 改后 |
|---|---|---|
| 单次目录变动 CPU | 5.1–5.3 s | **≈ 305 ms** |
| 墙钟 | 4.4–5.5 s | ≈ 0.3 s |
| 内存 | 新旧 listing 同时存在，峰值 +160 MB | 峰值几乎没有增长 |

17 倍的提升来自「不再重新枚举 100 万项」；剩下的 305 ms 里，160 ms 是重建 listing（复制 100 万个名字/属性
+ 47 ms 建 CFString），132 ms 是视图更新，10 ms 是模型。下一轮（阶段 D）会把这两块继续压下去。

### 7.3 边界情况

- 变更条目超过 128 个、或有非 ENOENT 的错误 → 自动退回全量刷新。
- 正在做全量加载 / 已有两个重载排队 / 处于平铺模式 / 有硬过滤 → 退回全量刷新。
- 目录本身的事件（`ShouldFire`）仍然会触发全量刷新。


### 7.5 变更合并（防抖）

FSEvents 的回调可能一秒内来几十次（解压、批量拷贝）。回调不再直接刷新，而是把条目名累积起来，
100 ms 后用一次补丁处理；期间若有加载/刷新正在进行，就继续往后顺延，不会丢更新。
累积超过 128 个名字时退回全量刷新。

实测（1M 目录）：创建 200 个文件 → 合并成一次全量刷新（2.3 s）；删除 200 个文件 → 3 次补丁
（每次 ~150 ms，合计约 0.45 s）。

### 7.4 新增的单元测试

`Source/Panel/tests/PanelData_UT.mm`：`ApplyPatchedListing`（删除+追加、只追加）验证条目数、名字查找、
排序顺序、以及选择状态在补丁后仍然保留。

