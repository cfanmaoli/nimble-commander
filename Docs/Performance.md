# 百万级文件性能评估

> 评估对象：Nimble Commander-Fork（branch `evil`，commit 9669c1a74）
> 评估日期：2026-11-06
> 环境：macOS 27.2，30 核 Apple Silicon，外置 NVMe（APFS），1.5 TB 空闲

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

- 数据集：`/Volumes/Data/bench/m1`，100 万个 13 字符名小文件
  （`f_0000000.txt` …），无扩展属性；另一组为 20 万个空子目录。
- 计时：`ps -o time=` 读进程累计 CPU，0.2 s 采样一次直到累计值 10 次不变（settle）；
  RSS 同一循环采集；`sample 1ms` 做函数级归因；`heap` 看分配构成。
- 内核底线用 `Scripts/perf/enum_baseline.c` 测（`readdir` 与 `getattrlistbulk` 两种属性集）。
- 排序微基准用一个临时的 ObjC++ 程序，1M 个 CFString、随机顺序（未入库）。

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

基准脚本在 `Scripts/perf/`（数据用 `gen.c` 现场生成）：

- `gen.c`：生成 N 个文件 / 子目录
- `enum_baseline.c`：`readdir` 与 `getattrlistbulk` 的裸基线
- `open_benchmark.sh` / `change_benchmark.sh`：首屏与变化响应的端到端测量

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


---

## 8. 第三轮：把增量刷新的 305 ms 拆开

加了更细的埋点后，单次目录变动的成本分布如下（1M 目录，k=1）：

| 阶段 | Brief 布局（默认） | List 布局 |
|---|---|---|
| 重建 listing（复制 100 万条目）| 152–171 ms | 151–163 ms |
| ├ 复制条目 | ~110 ms | ~97–107 ms |
| └ `Listing::Build`（含 1M 次 CFString）| ~54 ms | ~54 ms |
| 模型增量应用 | 11 ms | 11 ms |
| 视图更新 | **133 ms** | **16 ms** |
| 合计 | ~305 ms | **~180 ms** |

两个结论：

1. **List 布局下单次变动已经降到 ~180 ms**（改前 5.1 s，约 28 倍）。
2. **Brief 布局（默认布局）多出的 133 ms 全部是 `NCPanelBriefView onDataChanged` 里的
   `[m_CollectionView reloadData]` + `NCPanelBriefViewDynamicWidthLayout prepareLayout`**：
   该布局引擎对 100 万个 item 做全量重排。这不是 O(n) 的小常数问题，而是需要增量布局引擎才
   能真正解决的，先记在待办里；顺带把 Brief 视图的图标表清理也改成了每 64 次更新一次。

顺带做的小优化：

- `ProducePatchedListing` 现在会先查一次 `Listing::HasAnyDisplayFilenames()/HasAnyAddTimes()/
  HasAnySymlinks()/HasAnyTags()`，整类属性不存在时跳过 100 万次 `has()` 调用。
- 图标表清理在两个视图里都改成「小列表每次都做，大列表每 64 次做一次」。


---

## 9. 第四轮：把模型构建挪出主线程（阶段 B）

打开一个 100 万项的目录时，主线程原本要空等 200 ms 做建索引和排序。现在把它拆成两半：

- `Model::PrepareLoad()`（静态、可在任意线程）：分配 volatile data、跑两次排序（仍然是并发的）、
  建过滤索引、算统计。实现上是造一个临时的 `Model` 来复用现成的排序/过滤代码，不碰真正的模型。
- `Model::InstallLoad()`（主线程）：只是把准备好的数组 move 进来，微秒级。
- `Load()` 仍然存在，语义不变（= PrepareLoad + InstallLoad），所以所有既有调用方和测试不受影响。

`PanelController` 在后台队列里 fetch 完之后直接 `PrepareLoad`，主线程只做 `InstallLoad`。
排序顺序/过滤条件由主线程在派发前快照下来传进去（模型是主线程独占的）。

实测（1M 目录，先 fetch 后 prepare）：

```
[perf] fetch   n=1000002 enum=2226.3ms build=55.6ms total=2282.1ms
[perf] prepare n=1000002 vd=2.9ms sorts=198.8ms softfilter=0.2ms stats=5.3ms total=207.3ms
[perf] ui      n=1000002 modelLoad=0.0ms dataUpdated=33.6ms tail=76.1ms total=109.8ms
```

主线程阻塞从 **205 ms → 0 ms**，UI 阶段从 **330 ms → 110 ms**，总墙钟基本不变（200 ms 的活挪到了后台）。
新增单元测试验证 `PrepareLoad + InstallLoad` 与 `Load` 得到完全一致的状态。

**这一阶段的“渐进式首屏”还没有做**：真正的首屏 <100 ms 需要流式枚举（边枚举边出名字），
这属于阶段 D 的惰性属性工作，下一轮处理。


---

## 10. 第五轮：CFString 惰性化 + ASCII 快排（阶段 D 的一部分）

`Listing::Build` 原本给每个条目预建一个 CFString，1M 项就是 100 万次分配（47 ms + 约 50 MB）。
现在：

- **CFString 惰性化**：`m_FilenamesCF` 改成 `std::atomic<CFStringRef>[]`，`FilenameCF()` 命中才建、
  未命中时加锁建一次（双检），析构时逐个 `CFRelease`。
- **排序不再需要 CFString**：`IndirectListingComparator::CompareNames()` 对纯 ASCII 名字直接按字节
  比较（大小写不敏感 = `tolower` 逐字节比较，与 `CFStringCompare(kCFCompareCaseInsensitive)` 对
  ASCII 完全等价）；非 ASCII 或“自然排序”才回落到原来的 CFString 比较。
- **raw 名排序并行化**：`DoRawSort()` 超过 1 万项改用 `pstld::sort`。

实测（1M 目录）：

| 指标 | 改前 | 改后 |
|---|---|---|
| `Listing::Build` | 55 ms | **11 ms**（其中 filenames 47 → 3.6 ms）|
| `prepare`（排序+索引+统计）| 205 ms | **~175 ms** |
| 单次目录变动（List 布局）| ~180 ms | **~140 ms** |
| 载入后常驻内存 | 456 MB | **419 MB** |

`clang-format` 通过、9 个单元测试套件全绿（含 `Comparators_UT` 的排序语义校验）。
内存离 250 MB 的目标还有距离：剩下的主要是 listing 里 7 个 8 字节属性和 4 个 int 索引向量，
要做紧凑存储（name arena + 位域 + 按需属性）才能达到。


---

## 11. 第六轮：首屏预览（阶段 D 的首屏部分）

打开 100 万项目录时，用户要盯着空白窗口等 2.2 秒（内核枚举），这是整个流程里最难受的部分。
现在枚举可以提前收工：

- `Fetching::ReadDirAttributesBulk()` / `NativeHost::FetchDirectoryListingImpl()` 增加 `_max_items`，
  读满即停。
- 新虚函数 `Host::FetchDirectoryListingPreview(path, max_items, flags)`：默认返回 ENOTSUP（其它 host
  不支持就算了），`NativeHost` 覆盖它。
- `PanelController` 在正式枚举之前先取 4096 条（约 23 ms），`PrepareLoad`（约 3 ms）之后立刻装进面板，
  然后才继续读完整目录；完整列表到了再替换。只有目录确实大于 4096 条时才发预览，小目录不受影响。
  预览的安装带“旧 listing 指针”检查：如果期间已经有更新的列表装上去了，预览就直接丢弃。

实测（1M 目录）：

```
[perf] preview n=4096 ready=25.8ms
[perf] fetch   n=1000002 enum=2191.2ms build=11.9ms total=2203.3ms
```

**首屏从 ~2.2 s 降到 ~30 ms**（含准备与视图更新），完整列表仍在大约 2.4 s 后就位。
新增单元测试覆盖 preview 的条数上限、超量请求、以及 0 的非法参数。


### 11.1 顺带：补丁容器预分配

`ProducePatchedListing` 里 9 个稠密容器原本靠逐条 `insert` 触发 `vector::resize`，
100 万条会有多轮几何扩容与搬移。现在先按最终条数 `resize` 一次，逐条插入退化成纯赋值：

```
[perf] patchcopy n=1000004 copy=92.0ms build=11.1ms
[perf] incr.ui   n=1000004 model=11.2ms view=1.2ms total=12.4ms
```

单次目录变动（List 布局）：**~116 ms**（改前 5.1 s，约 44 倍）。

注意：预览期间面板里是完整的 4096 条真实条目，不是占位符——对它们做复制/删除等操作是安全的；
完整列表到达时会整体替换（行数变化走 `noteNumberOfRowsChanged`）。


---

## 12. 第七轮：Brief 布局不再为每个条目建布局属性（阶段 D 的内存部分）

用 `heap` 看一个 100 万项目录的 Brief 视图（默认布局）时发现了真正的内存大户：

```
 1000580  256148480  256.0   NSCollectionViewLayoutAttributes   ObjC  AppKit
  991811   31737952   32.0   NSIndexPath                        ObjC  Foundation
  991811   15868976   16.0   NSIndexPath._indexes (uint64_t[])   C     Foundation
```

三个 Brief 布局引擎（FixedWidth / FixedNumber / DynamicWidth）都在 `Layout()` 里为**每一个条目**
预先创建 `NSCollectionViewLayoutAttributes` 和 `NSIndexPath`，100 万项就是 256 MB + 48 MB，
而且每次重新布局都要重建一遍。

实际上这些属性完全可以从网格参数推导出来：`m_ColumnsPositions[]` / `m_ColumnsWidths[]` /
`m_RowsNumber` / `m_ItemHeight` 加起来只有几 KB。改动：

- `LayoutEngineBase` 去掉 `m_Attributes`，`AttributesForItemNumber()` 改为按需计算
  （列 = index / 行数，行 = index % 行数，frame 由两个数组给出）；
- `LogarithmicSearchForItemsInRect()` 只对可见范围内的条目创建属性；
- 三个引擎的 `Layout()` 只填列位置/宽度，不再碰条目级的属性对象。

实测（1M 目录，Brief 布局，同一脚本 A/B）：

| 指标 | 改前 | 改后 |
|---|---|---|
| Physical footprint | 649.6 MB | **359.1 MB** |
| 首次载入 UI 阶段 | ~130 ms | **~35 ms** |
| 单次目录变动的视图更新 | 133 ms | **17 ms** |
| 单次目录变动合计 | ~305 ms | **~132 ms** |

顺带说明最初把底噪量成了 ~340 MB——那次测量被“恢复上一个 1M 会话”污染了。干净的一次测量（只开两个
`/tmp` 面板、空目录、List 布局）是：

```
baseline (list, empty dirs): 154.3 MB
after 1M (list):             373.4 MB
```

也就是说 **应用底噪 ~154 MB，1M 项目的 listing+模型 ~219 MB**。理论估算 listing ~105 MB + 模型 ~40 MB
= 145 MB，多出来的 ~70 MB 是分配器开销与加载期的瞬时峰值。要达到“整机 ≤250 MB”，需要把 listing+模型
压到 ~95 MB，也就是 <45 B/行——这需要紧凑存储（name arena + 32 位时间戳 + 位域 + 精简索引），
是下一阶段的独立工作。


---

## 13. 第八轮：补丁式重建走 VFS 内部的批量拷贝

上一轮把单次变动压到 ~116 ms 之后，剩下的最大一块是 `ProducePatchedListing` 里逐条复制 100 万项
（~92 ms）：每项要 14 次访问器调用 + 9 次容器 `insert`，即使容器是稠密的也一样。

现在把补丁式重建搬进 VFS 内部（`Listing::ProducePatchedListing`），直接操作私有数组：

- 名字/扩展名偏移/mode/type 用连续数组拷贝；
- `sizes`/`inodes`/`atimes`/`mtimes`/`ctimes`/`btimes`/`uids`/`gids`/`unix_flags` 这些稠密列
  通过新增的 `variable_container::dense_values()` 拿到 `span`，按列拷贝（向量化友好）；
- 只支持“普通形状”的 listing（没有显示名/符号链接/标签）；带这些额外数据的走原来的通用实现。
  对每个追加项只做几次访问器调用，可以忽略。

实测（1M 目录，单次变动）：

| 阶段 | 改前 | 改后 |
|---|---|---|
| 重建 listing（List 布局） | 88–105 ms | **17–24 ms** |
| 单次变动合计（List） | ~116 ms | **~43 ms** |
| 单次变动合计（Brief，默认） | ~132 ms | **~65 ms** |

也就是说 **1M 目录的目录变动响应现在是 40–70 ms，已经达到 <100 ms 的目标**（相对最初的 5.1 s 约 120 倍）。

顺带修的两个坑（都被新增单元测试覆盖）：

- 源 listing 里“整列缺失”的属性（比如归档 listing 没有 uid/gid）以前会被当成稠密列读取越界，
  现在识别为缺失；
- 追加项写入时只在目标列确实存在时才写，避免把缺失变成 0。


---

## 14. 第九轮：ReLoad 也移出主线程（阶段 B 收尾）

`Model::Load` 上一轮已经搬到后台，但**全量刷新**路径（`Cmd+R`、一次性变更超过 128 项、平铺视图、
带硬过滤等）走的还是 `Model::ReLoad`——它要在主线程上重排 100 万项（~300–500 ms）。

现在同样拆成两半：

- `SnapshotForReload()`（主线程）：把旧 listing、volatile data、raw-name 顺序以及排序/过滤条件
  拷贝成一份快照（1M 项约 2–3 ms）；
- `PrepareReload()`（任意线程）：在临时 `Model` 上用快照复现原来的合并逻辑（`DoRawSort` +
  按名字合并 + 自定义排序 + 过滤索引 + 统计）；
- `InstallLoad()`（主线程）：只做数组 move，沿用上一轮的实现。

`Model::ReLoad` 本身保留，语义不变（= 快照 + 预处理 + 安装），所有既有调用方和测试不受影响。

实测（1M 目录，一次性新增 200 个文件触发全量刷新）：

```
[perf] fetch n=1000202 enum=2243.4ms build=11.1ms total=2254.7ms
[perf] prepare.reload n=1000202 sort+merge=179.7ms rest=5.0ms
```

原本压在主线程的 ~300–500 ms 合并现在在后台队列里花 ~185 ms，主线程只做最后的安装。
剩下的大头仍是内核枚举（2.2 s）——那是全量刷新的固有成本，只有增量路径能绕开。


---

## 15. 第十轮：枚举结果直接移交给 listing + 内存测量注意事项

### 15.1 少一次 100 万字符串的拷贝

`Listing::Build` 原本把枚举器填好的 `std::vector<std::string>` 复制进 `unique_ptr<std::string[]>`，
再销毁源 vector——100 万项就是 24 MB 的复制 + 一份 34 MB 的临时内存（vector 的容量会超调）。
现在 listing 直接**接管**这些 vector（`m_Filenames`/`m_UnixModes`/`m_UnixTypes` 改为 `std::vector`）：

```
[perf] build n=1000002 validate=0.4ms compress=5.1ms move=0.0ms filenames=3.4ms total=8.9ms   (改前 11.1ms)
```

### 15.2 内存测量在这个环境里的坑（重要）

记录一下我在做内存 A/B 时踩的坑，避免以后重复：

1. **启动时可能自动打开上一次的目录**：即使删掉 `State/` 和 `~/Library/Saved Application State/...`，
   应用仍可能在启动后导航到某个大目录——这是被 LaunchServices 排队投递的 `open` 事件造成的（压测脚本
   大量使用 `open -a`）。所以“空转底噪”必须在一个从没被 `open` 过的会话里量，否则基线里已经躺着一份 listing。
2. 因此 `ps`/`vmmap` 的绝对值在压测脚本之间不可比；可比的是**同一次进程内**“打开前 vs 打开后”的差值，
   或者 `heap` 的 zone 总量（活对象）。
3. 试过在 1M 载入后调用 `malloc_zone_pressure_relief()` 把临时页还给系统：A/B 测量（zone 与 footprint）
   都没有可见收益，已回退，不留这段代码。

### 15.3 当前内存账本（干净的 1M 会话）

| 项 | 大小 |
|---|---|
| 应用空转（两个空 `/tmp` 面板，List 布局） | 154 MB footprint |
| 1M 项的 listing + 模型 | ~214 MB（`heap` zone 总量），理论值 ~145 MB |
| 其中 listing | ~105 MB |
| 其中模型（volatile data 24 B + 4 个索引向量 16 B 每行） | ~40 MB |
| 其余 | 分配器开销 + 载入期的临时/超调容量 |

要达到整机 ≤250 MB，需要 listing+模型 ≤96 MB，即 **<45 B/行**——这需要动 `VFSListing` 的存储布局
（name arena、时间戳压缩、属性按需），属于一次高风险的大改造；本轮先没有动。


---

## 16. 第十一轮：时间列压到 32 位（紧凑存储第一步）

listing 里五个时间列（atime/mtime/ctime/btime/add_time）原本是 `time_t`（8 字节），100 万项就是 40 MB。
现在内部存 32 位纪元秒（覆盖 1901–2038），对外接口仍然返回 `time_t`：

- `Listing::m_{A,M,C,B,Add}Times` 改成 `variable_container<int32_t>`；
- `Build()` 里用 `CompactTimes()` 从 `ListingInput` 的 `time_t` 容器转换（common/dense/sparse 三种模式都处理，
  超出范围的钳到 int32 边界）；
- 补丁路径 `ProducePatchedListing()` 直接按 int32 拷贝，追加项写入时同样钳位。

实测（`heap` 的 zone 总量，1M 目录）：214,264,977 → **189,614,497 字节（-24.6 MB）**。

取整机 footprint 依旧受"启动时可能被投递 open 事件"的干扰影响，所以这里用 zone 总量做验收指标。


---

## 17. 第十二轮：给 listing 加一个确定性的内存账本

footprint 在压测环境里不可比（启动时可能被投递 `open` 事件，基线里多或少一份 listing），所以给
`Listing` 加了一个 `ApproximateMemoryFootprint()`：把各个数组/容器的实际占用加起来（不含惰性
materialize 的 CFString），并打进 `NC_PERF_LOG` 的 build 行：

```
[perf] build n=1000002 mem=92.9MB validate=0.4ms compress=5.4ms move=1.5ms filenames=3.7ms total=11.0ms
```

**100 万项的 listing 本体现在是 92.9 MB**（时间列压缩前是 ~113 MB）。组成大致是：

| 部分 | 大小 |
|---|---|
| filenames（`std::string` × 1M）| 24 MB |
| CFString 指针表（惰性） | 8 MB |
| 5 个时间列（32 位） | 20 MB |
| sizes + inodes | 16 MB |
| uid/gid/unix_flags | 12 MB |
| 扩展名偏移 + mode + type | 5 MB |
| 其余（标题、hosts/directories 等） | ~8 MB |

加上模型的 ~40 MB（volatile data 24 B/行 + 4 个索引向量），100 万项目录的**数据面**约 133 MB；
再加应用底噪 ~154 MB，整机约 287 MB。

离 250 MB 还差 ~37 MB，可选项（按风险从低到高）：

1. CFString 指针表改成稀疏表（只存可见行的 materialize 结果）：-8 MB；
2. 软过滤索引在无过滤时不预分配（空 == 恒等）：-4 MB；
3. `inode`/`uid`/`gid`/`ctime` 不进 listing，改为按需 stat（影响 Get Info 与拷贝里的硬链接判断）：-20 MB；
4. 名字 arena（`Filename()` 返回 `string_view`）：实测只省 ~6 MB，但要改几百处调用点——不划算，已否决；
5. 时间/大小列按需（惰性元数据模式）：-30 MB 以上，但会改变"表格里直接看得到大小和时间"的行为。

下一轮按 1+2+3 的顺序做（每步都跑测试、量 `mem=` 与 zone 总量），做到 3 时再评估是否值得。


---

## 18. 第十三轮：软过滤索引改为"空即恒等"，并否决剩余两个内存方案

### 18.1 改动

没有软过滤时，`Model::BuildSoftFilteringIndeces()` 原本会 `resize + iota` 出 100 万项的索引数组（4 MB），
而现在直接留空，语义变成"空数组 == 恒等映射"：

- 新增 `Model::SoftFilteredCount()` / `Model::SortIndexForSoftFiltered(pos)`；
- `QuickSearch` 的 6 处调用点改用这两个访问器；
- 过滤激活时行为不变（测试 `QuickSearch_UT` 覆盖）。

顺带把增量更新的模型阶段从 ~20.5 ms 压到 ~17 ms（少了一次 4 MB 的 iota 填充）。

### 18.2 否决清单（有据可查，避免以后重复评估）

| 方案 | 预估收益 | 否决原因 |
|---|---|---|
| 名字 arena（`Filename()` → `string_view`） | ~6 MB | 13 字符的名字走 SSO，`std::string` 本身只有 24 B；要改几百处调用点 |
| CFString 指针表改稀疏表 | ~8 MB | 非 ASCII 目录（中文字符串！）排序会回落到 `CFStringCompare`，稀疏表 + 锁会让 2000 万次比较变成秒级 |
| `uid`/`gid`/`ctime` 不进 listing | ~12 MB | "属性"对话框直接读它们显示当前用户/组；改成按需 stat 会让批量选中时的对话框变慢 |
| `inode` 不进 listing | ~8 MB | `CopyingJob` 用它对每个被拷贝的项做硬链接/自拷贝判断；改成逐项 stat 会拖慢大目录拷贝 |

### 18.3 结论

在保留"表格里直接能看到大小/时间/所有者"这一完整语义的前提下，100 万项目录的数据面已经压到
`listing 92.9 MB + 模型 ~36 MB ≈ 129 MB`，整机约 **283 MB**。

要再往 250 MB 走，唯一的办法是"惰性元数据模式"——时间/大小列只对可见行取，代价是表格里不再
立刻能看到这些值和"按大小/时间排序"需要先做一次全量 stat。这是一个**产品取舍**，不是纯工程优化；
代码里没有默认开启它。


---

## 19. 第十四轮：名字-only 枚举（惰性元数据的地基）

新增 `VFSFlags::F_NamesOnly`：`NativeHost` 在这个标志下用 `readdir()` 而不是 `getattrlistbulk()`，
只填文件名和条目类型（DT_REG/DT_DIR/…），**完全不取属性**——100 万项的枚举从 2.2 s 降到
~0.6 s（readdir 的实测下限）+ 一次 ~50 ms 的构建。

实现要点：

- 大小/时间/inode/uid/gid/flags 这些容器全部留空（sparse 空），所以 `HasSize()`/`HasMTime()` 等
  一律返回 false，调用方可以据此判断\“属性还没取\”；
- `PanelData::InitVolatileDataWithListing()` 增加了 `HasSize()` 检查（以前默认 listing 一定带 size）；
- 时间列压缩 `CompactTimes()` 现在会把\“空的稠密容器\”也识别为\“属性缺失\”，不再填 0；
- 只对本地 IO 生效（Admin Mode 下退回原来的路径）。

这条路径目前还没有接到界面上——它是\“惰性元数据模式\”的地基：面板只枚举名字，
然后对可见行按需 `stat`。要把它变成可用功能，还需要视图侧的占位符、可见行取属性的调度，
以及\“按大小/时间排序\”时的全量回补。是否要做成可选模式（默认关）等你的决定。

新增单元测试：`Names-only listing carries no attributes`（条目数/名字/类型正确，属性确实缺失）。


---

## 20. 阶段总结（截至现在）

### 20.1 达成情况

| 指标 | 起始 | 现在 | 目标 | 状态 |
|---|---|---|---|---|
| 1M 目录首屏 | ~2.2 s | **~34 ms**（预览）| <100 ms | ✅ |
| 1M 目录全量就绪 | ~5.7 s CPU | **~2.35 s**（枚举 2.17 s 为主）| — | ✅ |
| 目录变动响应（List 布局）| 5.1 s | **~40 ms** | <100 ms | ✅ |
| 目录变动响应（Brief/默认）| 5.1 s | **~65 ms** | <100 ms | ✅ |
| 主线程阻塞（打开/刷新）| 205–500 ms | **0 ms**（全部在后台队列）| — | ✅ |
| Brief 1M footprint | 649.6 MB | **359 MB** | — | ✅ |
| 1M listing 数据 | ~105 MB（8 字节时间戳）| **92.9 MB** | — | ✅ |
| 整机常驻（默认）| ~650 MB | **~283 MB** | ≤250 MB | ⚠️ 见下 |
| 整机常驻（惰性日期+大小）| ~650 MB | **~252 MB** | ≤250 MB | ✅ 基本达标 |

> 注（第十九轮之后补记）：上表的“目录变动响应”是**默认视图选项**下的数字。第十六轮之前，默认选项下
> （隐藏文件不显示）增量路径其实一直被 `HardFiltering().IsFiltering()` 挡掉、退化成 2.4 s 的全量刷新，
> 之前测到的 40 ms 是在“显示隐藏文件”时测的——该问题已在第 22 章修复，上表是修复后的数字。
> 惰性模式（`lazyDates`/`lazySizes`，默认关）把 listing 数据从 92.9 MB 降到 61.8 MB，整机因此从
> ~283 MB 降到 ~252 MB，代价是大小/日期列要滚动到才显示、按这两列排序会先做一次全量属性重读。

最近一次实测：

```
[perf] preview n=4096 ready=34.2ms
[perf] fetch   n=1000002 enum=2157.1ms build=12.4ms total=2169.7ms
[perf] prepare n=1000002 vd=3.9ms sorts=173.2ms stats=5.3ms total=182.4ms
[perf] ui      n=1000002 modelLoad=0.0ms dataUpdated=14.8ms total=15.0ms
[perf] incr    k=1 removed=0 appended=1 fetch=0.3ms patch=17.5ms
[perf] incr.ui n=1000004 model=19.0ms view=1.4ms total=20.4ms
```

### 20.2 为什么停在 283 MB

要再降到 250 MB，唯一的办法是\“惰性元数据模式\”：只枚举名字（`F_NamesOnly` 已经实现，
1M 项 0.6 s），表格里的大小/时间列只对可见行按需 `stat`。代价：

- 表格里不再\“立刻\”看到大小/修改时间/创建时间（要滚动到才取）；
- 按大小或时间排序需要先做一次全量 stat（2.2 s）。

这是产品取舍，不是纯工程优化——代码里没有默认开启。地基（names-only 枚举）已经就位并有测试覆盖，
要接成可用的可选模式还需要：视图占位符、可见行取属性的调度与缓存、排序列的全量回补。

### 20.3 全部相关提交（evil 分支，均未推送）

```
f76eab139 第一轮：Brief 宽度测量封顶 / 显示名限流 / 1MB 枚举缓冲 / 表格批量更新
e95e70c75 PrepareLoad：模型准备移出主线程
82f0898df 惰性 CFString + ASCII 快排 + 并行 raw 排序
9b2e5b249 首屏预览（F_NamesOnly 的前身：FetchDirectoryListingPreview）
835440888 补丁容器预分配
19f7ae8b1 Brief 布局属性按需（-290 MB footprint）
8b8326392 FSEvents 路径级增量刷新
5f2268d6e 变更合并（防抖）
252540ce6 属性存在性快速检查 + 图标表清理节流
7863b4ea2 PrepareReload：全量刷新也移出主线程
3cb8fafc4 补丁式重建走 VFS 内部批量拷贝（变动 5.1s → 43ms）
c0855bc7f 枚举 vector 直接移交
a1b6ea6d8 内存基线修正
150367eaa 时间列 32 位（-24.6 MB）
aeacf91b4 listing 内存账本（mem=92.9MB）
7a254cff8 软过滤索引空即恒等（-4 MB）
544e5788b 名字-only 枚举（F_NamesOnly）
```


---

## 21. 第十五轮：F_NoTimes（惰性日期列的地基）

目标是把五个时间列从常驻内存里拿掉（1M 项 = 20 MB），同时保留大小/inode/uid/gid/flags。
新增 VFSFlags::F_NoTimes：

- Fetching::ReadDirAttributesBulk() 多一个 _with_times 参数，为 false 时 attrlist 不请求
  CRTIME/MODTIME/CHGTIME/ACCTIME/ADDEDTIME；
- NativeHost 在 F_NoTimes 下把时间容器全部留成 sparse-empty，并且 fill() 不写时间字段
  （CompactTimes() 会把“空稠密容器”识别为缺失，见第 16/19 章）；
- 结果：listing 有 HasSize()/HasInode()/HasUID() 等，但 HasMTime() 等一律为 false。

内核枚举时间没有明显变化（~2.17 s → ~2.2 s，瓶颈不在属性多少），收益纯粹在内存。
按账本估算，1M 项的 listing 会从 92.9 MB 降到约 72.9 MB（-20 MB），接到面板上之后再复测。

新增单元测试：F_NoTimes drops the time columns but keeps the rest（大小/inode 在、时间不在）。


---

## 22. 第十六轮：增量刷新在默认视图选项下其实没生效（已修）+ 惰性日期模式

### 22.1 一个被压测环境掩盖的真问题

做惰性日期的联调时发现：**默认配置下（隐藏文件不显示，`HardFilter::show_hidden == false`）**，
`refreshPanelIncrementallyWithChangedNames:` 一进门就命中

```objc
m_Data.HardFiltering().IsFiltering()   // show_hidden==false 时恒为 true
```

于是每次目录变动都退回**全量刷新**（1M 目录 = 2.4 s）。之前的基准里这个分支没被触发，是因为压测脚本
跑过若干轮后把 `show_hidden` 留成了 true——也就是说文档里早先的“43 ms”是在隐藏文件显示的状态下测的。

修复分两处：

- `Model::ApplyPatchedListing()` 现在会按 `m_HardFiltering` 过滤**新增条目**（被过滤掉的不进
  `m_EntriesByCustomSort`），`m_ReverseToCustomSort` 只对可见条目建映射；
- `PanelController` 去掉增量路径上的 `HardFiltering().IsFiltering()` 守卫。

修复后（1M 目录、默认隐藏文件、List 布局）：

```
[perf] incr k=1 removed=0 appended=1 mem=81.1MB fetch=0.1ms patch=8.1ms
[perf] incr.ui n=1000005 model=11.5ms view=19.5ms total=31.0ms
```

即 **~39 ms**，而修复前是 ~2.4 s 的全量刷新——默认配置下提升约 60 倍。

### 22.2 惰性日期模式（默认关）

配置项 `filePanel.general.lazyDates`（默认 `false`）。开启后：

- 目录大于预览阈值时用 `F_NoTimes` 枚举，listing 不再带五个时间列；
- 日期列对未取到的行显示 `--`；
- 载入后对**最前面 200 个排序项**批量 `stat`（后台队列），结果存进模型的 `FetchedTimes` 覆盖表，
  只刷新这些行；滚动时按需补取（目前只做首屏，滚动补取还没接）。

实测（1M 目录）：

```
listing mem=69.5MB   （完整属性时 92.9MB，-23.4 MB）
[perf] incr k=1 ... mem=77.2MB fetch=0.1ms patch=56.0ms   （补丁走通用路径，因为时间列是空的）
[perf] incr.ui ... total=32.1ms
```

### 22.3 验证

- 9 个套件全绿；`clang-format --check` 通过；app 重编译/签名/安装。


---

## 23. 第十七轮：惰性日期的补取范围 + 补丁快速路径支持缺失时间列

### 23.1 惰性日期的取数范围

- 载入后取排序位置 `[0, 200)`；
- **光标移动时**取 `[cursor-20, cursor+200)`（键盘移动/点击都会触发），已取过的行不会重复 stat
  （`Model::FetchedTimesAtRawPos` 命中即跳过）。

鼠标滚轮滚动不移动光标，这一块还没接 `NSScrollView` 的 bounds 通知——属于后续工作，
目前滚动到远处时会先看到 `--`，点一下或按方向键数据就回来了。

### 23.2 补丁快速路径允许缺失的属性列

`Listing::ProducePatchedListing()` 之前要求时间列必须是 dense/common，惰性日期模式下时间列是空的，
于是每次都退回通用补丁（~56 ms）。现在\“空容器\”被视为可补丁的：结果列保持为空，
只有新增条目自带的时间会以稀疏方式写进去。

实测（1M 目录、惰性日期模式）：首次补丁走快速路径（~20 ms），之后再产生稀疏时间列时仍会退回通用路径
（~56 ms）——两者都在 100 ms 以内。


---

## 24. 第十八轮：`F_NoSizes` —— 完全惰性模式把数据面压到 ~98 MB

### 24.1 改动

新增 `VFSFlags::F_NoSizes` 与配置项 `filePanel.general.lazySizes`（默认关）：

- `Fetching::ReadDirAttributesBulk()` 增加 `_with_sizes` 参数，为 false 时 attrlist 不再请求
  `ATTR_FILE_DATALENGTH`（解析端本来就会把缺失的大小记为 -1，无需改动）；
- `NativeHost` 在 `F_NoSizes` 下把 size 容器留成 sparse-empty、`fill()` 不写、`resize_dense()` 也不再增长它；
- 面板取数时同时把大小写进 `ItemVolatileData::size`（`Model::SetFetchedSize`），
  `PanelListViewSizeView` 在 `!item.HasSize()` 时读 vd，取不到就显示空；
- 大小与日期的惰性取数共用一条队列和同一套“光标附近 + 首屏 200 行”的策略。

### 24.2 实测（1M 目录）

| 模式 | listing 数据 | 数据面（listing + 模型 ~36 MB）|
|---|---|---|
| 完整属性（默认） | 92.9 MB | ~129 MB |
| 惰性日期 | 69.5 MB | ~105 MB |
| **惰性日期 + 惰性大小** | **61.8 MB** | **~98 MB** |

加上应用自身底噪（干净测量 ~154 MB），完全惰性模式整机约 **252 MB**，基本达到 250 MB 的目标；
默认模式仍是 ~283 MB。两个开关都默认关闭，因为开启后大小/日期列要滚动到才会显示。

### 24.3 增量路径（完全惰性模式）

```
[perf] incr k=1 removed=0 appended=1 mem=77.2MB fetch=0.1ms patch=57.7ms
[perf] incr.ui n=1000005 model=12.0ms view=20.6ms total=32.6ms
```

合计 ~90 ms，仍在 100 ms 以内；首次补丁走快速路径（~20 ms），之后因为出现稀疏时间列退回通用路径。

### 24.4 验证

- 新增单元测试 `F_NoSizes drops the sizes but keeps the times`；
- 9 个套件全绿（VFSUT 42714/69 等）；`clang-format --check` 通过；app 重编译/签名/安装。


---

## 25. 第十九轮：惰性模式的收尾（滚动补取、排序回退、去重）

### 25.1 滚动补取

`PanelListView` 现在监听 `NSViewBoundsDidChangeNotification`（`contentView.postsBoundsChangedNotifications`），
把 `rowsInRect:` 得到的可见排序区间通过 `PanelViewDelegate` 的
`panelView:visibleSortedRangeChangedTo:` 交给面板，面板再取 `[可见区间 ± 100]` 的属性。

### 25.2 排序回退

惰性模式下按大小/时间排序是没有意义的（这些列不在内存里），所以 `changeSortingModeTo:` 检测到
新的排序需要属性时，会关掉当前面板的惰性开关并触发一次**全量属性刷新**，之后再排序。

### 25.3 去重

滚动通知会在结果回来之前连发很多次，所以加了 `m_LazyPending`（在途索引集合）：正在取的索引不会重复排队；
同时用 `Model::HasFetchedSize()` / `FetchedTimesAtRawPos()` 跳过已经取到的行。

实测同一次载入 + 自动滚动过程中单条目 stat 次数：**1280 → 440**（首屏 200 + 光标窗口 220 + 少量几何变化）。

### 25.4 验证

- 9 个套件全绿（VFSUT 42732/69 等）；`clang-format --check` 通过；app 重编译/签名/安装；
- 惰性模式实测：`listing mem=61.8MB`，载入、增量、取数均无异常。


---

## 26. 第二十轮：测量方法修正 + 裁掉向量容量超调

### 26.1 终于找到 footprint 不可比的根因

之前每次压测的“基线”里都可能已经躺着一份 1M listing。根因不是 LaunchServices、不是 State.json、也不是
任何配置文件——是 **Cocoa 的窗口恢复（window restoration）**：即使删掉
`~/Library/Saved Application State/info.filesmanager.Files.savedState` 和四个 App Support 目录里的
`State`，AppKit 仍会把上次的窗口/标签恢复出来（它会自己重新落盘）。

干净的测法是在启动时加参数：

```
/Applications/Nimble Commander-Fork.app/Contents/MacOS/Nimble Commander-Fork -ApplePersistenceIgnoreState YES
```

加了这个参数之后，启动日志里就只剩 `default content left=/Users/me/ ...` + 一次 `goto request=...`，
不再出现莫名其妙的大目录。临时的 `[perf] goto` / `[perf] default content` 埋点已经移除。

顺带把**目录路径**加进了 `[perf] fetch` 行（`dir=/...`），以后排查“谁在读这个目录”会快很多。

### 26.2 直接测量（干净启动 + 打开 1M 目录）

| 模式 | 空转基线 | 打开 100 万项目录后 |
|---|---|---|
| 完整属性（默认）| ~105 MB | **~400 MB**（两次干净测量：393 / 402 MB）|
| 惰性日期 + 惰性大小 | ~105 MB | **~270 MB**（269.9 / 271.9 MB）|

**这比之前文档里估算的 283 / 252 MB 要高**：之前的估算是“底噪 + listing 账本 + 模型”，漏掉了
载入期一次性分配的容器（`ext_flags`/`devs` 各 8 MB、排序索引数组、枚举缓冲区等）在 malloc 里被保留的页面。
结论：**默认模式约 400 MB，惰性模式约 270 MB，250 MB 的目标没有真正达到**（差 ~20 MB）。

试过在载入后调用 `malloc_zone_pressure_relief()` 把临时页还给系统：干净 A/B 下 footprint 没有稳定收益
（多次测量抖动 270–380 MB，甚至有 944 MB 的离群值），已回退，不留这段代码。

### 26.3 本轮保留的改动：裁掉向量容量超调

枚举器按几何增长填向量，100 万项会带上十几%的空容量。`Listing::Build` 在接管这些向量后按
`capacity > size * 1.06` 做 `shrink_to_fit()`（一次 ~3 ms 的拷贝）：

```
默认模式：mem=92.9MB -> 81.1MB   (-11.8 MB)
惰性模式：mem=61.8MB -> 54.4MB   (-7.4 MB)
```

`mem=` 是 `Listing::ApproximateMemoryFootprint()`，不受 footprint 抖动影响，可作为确定性的回归指标。


---

## 27. 第二十一轮：把内存账算细（活数据 vs footprint）

### 27.1 本轮改动

- `devs`/`ext_flags` 两个临时向量（各 8 MB / 100 万项）现在只在真正需要时才分配：
  `devs` 仅用于本地化显示名 pass（`F_LoadDisplayNames`），`ext_flags` 用于显示名和 Finder 标签
  （`F_LoadTags`）。基准里两者都没开，于是这 16 MB 完全不分配。
- `variable_container` 增加 `shrink_to_fit()` / `capacity()`；`Listing::Build()` 除了 filenames/modes/types，
  现在也把 sizes/inodes/uid/gid/flags 这些 dense 容器裁到精确大小。
- `ApproximateMemoryFootprint()` 改为按 **capacity** 统计（以前只统计 size，掩盖了向量的超调容量）。

### 27.2 干净的账（默认模式，1M 目录，`-ApplePersistenceIgnoreState YES`）

```
heap zones (live):  20.4 MB  ->  195.0 MB     (+174.6 MB)
physical footprint: 107.6 MB ->  396.2 MB     (+288.6 MB)
```

也就是说：**活数据只涨了 ~175 MB，footprint 却涨了 ~289 MB**，其中 ~114 MB 是 malloc 保留的空闲页
（大块分配的区域即使释放也不会立刻还系统，`malloc_zone_pressure_relief()` 对此无效，已实测过两次）。

活数据的构成（估算）：listing 81.1 MB（`mem=`）+ 模型 ~36 MB + 排序/准备阶段的数组 + 视图与图标缓存。

### 27.3 当前结论

| 模式 | 空转 | 1M 目录 | 相对 250 MB |
|---|---|---|---|
| 完整属性（默认）| ~108 MB | **~396 MB** | 超 |
| 惰性日期 + 惰性大小 | ~105 MB | **~271 MB** | 超 ~21 MB |

惰性模式要再降 ~21 MB 才达标，可选的手段按收益/风险排序：

1. `ItemVolatileData` 的 highlight 字段（8 B/项 = 8 MB）改成稀疏 map —— 只在快速搜索时有值；
2. 惰性 CFString 指针表（8 MB）改成小 map —— 只存实际 materialize 过的可见行；
3. `m_Inodes`（8 MB）在惰性模式下不存，拷贝时的硬链接判断退化为一次 `stat`；
4. 大数组改用 mmap 分配器，释放即 `munmap`（能把 malloc 保留的那 114 MB 里的一部分真正还给系统）。

前两项合计 ~16 MB、风险低，是目前看来最划算的；第 3 项有功能代价；第 4 项收益最大但要动分配器，风险最高。


---

## 28. 第二十二轮：把快速搜索的高亮移出每项结构（活数据 -16 MB，footprint 不动）

### 28.1 改动

`ItemVolatileData` 从 24 B 降到 16 B：`QuickSearchHighlight`（8 B）不再是每项字段，改成模型里的
侧挂数组 `m_Highlights`——**只在快速搜索真正要高亮时才分配**（`ResetHighlights()` 时释放并 `shrink_to_fit`）。

牵连的读点都改成按行取：

- `PanelListViewRowView` / `PanelBriefViewItem` / `NCPanelGalleryCollectionViewItem` 各加一个
  `qsHighlight` 属性，由各自的视图在填数据时从模型取（`HighlightForRawIndex` / 新增的
  `HighlightForSortPosition`）；
- 30 处测试断言从 `VolatileDataAtSortPosition(n).highlight` 改为 `HighlightForSortPosition(n)`。

### 28.2 实测：活数据降了，footprint 没降

```
默认模式：heap zones 195.0 MB -> 176.7 MB（-18.3 MB），footprint 396.2 -> 393.1 MB（噪声内）
惰性模式：heap zones  -> 154.7 MB，footprint ~272 -> ~277 MB（噪声内）
```

这印证了上一轮的结论：**footprint 由 malloc 保留的空闲页主导（~114 MB），减少稳态活数据不会让它下降**；
要压 footprint 只能压**峰值分配**（枚举期的中间容器、排序索引、裁容量时的拷贝本身也是峰值）。

### 28.3 结论

当前 footprint：默认 ~390 MB / 惰性 ~272 MB，距 250 MB 目标仍差 ~22 MB。
后续要真正达标的路线只剩两条，都需要动架构：

1. **枚举直接写进最终容器**（去掉 `ListingInput` 中间层与容量超调），把峰值从 ~150 MB 压到 ~60 MB；
2. **大数组用 mmap 分配器**，释放即 `munmap`，把 malloc 保留的页真正还给系统。

两者都要改 VFS 的枚举与存储层，属于多轮工作；在没确认值得之前不建议贸然动。


---

## 29. 第二十三轮：把压测脚本收进仓库 + 活内存的进一步拆解

### 29.1 `Scripts/perf/`

之前的基准脚本散在仓库外的一个临时目录里，无法复现。现在收进仓库：

- `Scripts/perf/gen.c` —— 生成 N 个小文件的测试目录；
- `Scripts/perf/open_benchmark.sh` —— 首屏/载入耗时 + 载入前后的 footprint；
- `Scripts/perf/change_benchmark.sh` —— 单次目录变动的响应；
- `Scripts/perf/README.md` —— `NC_PERF_LOG` 各行含义、以及三条踩坑记录：
  1. 必须用 `-ApplePersistenceIgnoreState YES` 启动，否则 AppKit 会恢复上次的 1M 目录，基线被污染；
  2. footprint 由分配器保留的空闲页主导，稳态数据变小它不会动 —— 回归看 `mem=`，活内存看 `heap`；
  3. 在应用退出过程中 `open -a` 会留下排队事件，下一次启动会被投递。

冒烟测试（1M 目录）：`baseline 100.1M -> loaded 394.3M`，`preview ready=16.7ms`、`enum=2716ms`，
与手工测量一致。

### 29.2 惰性模式的活内存拆解

```
heap All zones: 142.9 MB  （空转 20.4 MB）
  其中 non-object（裸 malloc 块）116.9 MB
  我们自己的账：listing 54.4 + 模型 ~28 + 其他 ~85 MB 合计只能解释约 85 MB
  最大的几块：30.2 MB、23.4 MB（filenames）、15.1 MB、7.8 MB×2、7.6 MB（inodes）…
```

也就是说还有一块 **~30 MB 的裸分配没有对上账**。下一步要在分配点埋点（或接 `malloc_history`）
把这块定位出来——如果它是可避免的临时/重复容器，footprint 还有机会再降 ~30 MB，那才是真正能把
惰性模式推近 250 MB 的路径。


---

## 30. 第二十四轮：容器容量核查（没有隐藏的浪费）

在 `Listing::Build` 与 `Model::InstallLoad` 里临时打印了各容器的 size/capacity：

```
[perf] cap listing names=1000002/1000002 modes=1000002/1000002 types=1000002/1000002 atomics=1000002
[perf] cap vd=1000002/1000002 rawname=1000002/1000002 custom=1000002/1000002 reverse=1000002/1000002
```

**所有常驻容器的容量都精确等于大小**——之前的裁剪已经到位，没有隐藏的超调。`heap -addresses all` 里
那些 30 MB / 15 MB 的大块是**已释放的临时缓冲**（`heap` 的地址清单会列出 zone 里登记过的块，
包含已 free 的），不是常驻浪费。

### 惰性模式 ~272 MB 的实际构成（1M 目录）

| 部分 | 大小 |
|---|---|
| 应用空转 | ~20 MB |
| listing（惰性日期+大小）| 54.4 MB |
| 模型（vd 16 + 三个索引 4×3）| 28 MB |
| AppKit（collection view 的 `_globalItems` 8 MB、Brief 宽度表 2 MB、字体/图标缓存…）| ~22 MB |
| 载入期仍被 hold 的临时缓冲 | ~20 MB |
| 分配器保留的空闲页 | ~75–120 MB（随运行历史波动）|

剩下的可动项只有模型里的 `ItemVolatileData`（16 B/项 = 16 MB）：它现在装着 size(8) + icon(2) + flags(2)。
如果惰性模式下把 size 也改成按需（放进稀疏 map），单这一项就能再省 ~12 MB，惰性模式有望到 ~260 MB；
但那需要动“目录大小计算”“按大小排序”等多处语义，属于又一轮改造。

结论：**在不动这些语义的前提下，惰性模式的 footprint 就是 ~270 MB 量级**；250 MB 需要再做一轮
`ItemVolatileData` 瘦身（以及接受随之而来的语义取舍）。


---

## 31. 第二十五轮：给惰性属性/高亮的模型 API 补测试

惰性日期/大小和快速搜索高亮都改成了模型侧的按需存储，但没有单元测试覆盖。本轮补上（`PanelData_UT`）：

- `FetchedTimes and the lazy attributes` —— `SetFetchedTimes`/`FetchedTimesAtRawPos`/
  `SetFetchedSize`/`HasFetchedSize` 的读写、越界请求被忽略、重新载入后清空；
- `Quick-search highlights live next to the volatile data` —— 高亮的读写、按原始索引与按排序位置
  两种取法一致、未设置的相邻项为空、重新排序（无过滤器时）会清空高亮。

PanelUT 从 56 个用例 / 1359 断言增加到 58 / 1382，全部套件仍然全绿。


---

## 32. 修复：大目录无法滚动（预览 listing 之后表格高度没更新）

**现象**：打开一个条目数超过 4096 的目录后，鼠标滚轮和滚动条都无法滚动，往下只能看到前几十行。

**根因**：首屏预览（4096 行）装好之后，完整 listing 再把它替换掉，行数变化 >1000，而
`PanelListView::onDataChanged` 当时用的是 `noteNumberOfRowsChanged`——它不会重新计算表格的
文档高度，于是外层的 `NSScrollView` 认为内容只有 4096 行那么高，滚动条自然滚不动、滚轮也被吃掉。
这是第一批性能改动（"避免对 1M 行调用 insertRows"）引入的回归，只有走预览路径的大目录才会命中。

**修复**：大范围行数变化改用 `reloadData`（`insertRows` 仍然只用于小范围增量）：

```objc
const int row_delta = std::max(new_rows_count, old_rows_count) - std::min(new_rows_count, old_rows_count);
if( row_delta > 1000 )
    [m_TableView reloadData];
```

顺带修掉了惰性模式下同类的一个隐患：取数完成后不再调用整表 `dataUpdated`（Brief 视图会因此
`reloadData` 并跳回开头），改为把"填充一行的所有列"抽成 `fillRowView:atRow:`，
由 `volatileDataChanged` 只重绘可见行。

**验证**（截图对比滚动前后 + 日志）：

- 20000 项目录、完整属性模式：滚动后可见行从 l_000000 变为 l_000062 ✓
- 20000 项目录、惰性日期+大小模式：同样滚动 ✓，并且滚动过程中触发了 286 次单条目 stat
  （说明可见行补取在滚动时正常工作）；
- 9 个单元测试套件全绿；增量刷新仍为 patch 7.4 ms + ui 31.5 ms。

另：用户的 `Config.json` 里残留了压测脚本写入的 `lazyDates`/`lazySizes`（`true`），已清掉，
恢复成出厂默认（这些键不写即等于 false）。


---

## 33. 修复：平铺视图会静默丢弃大量条目

**现象**：对 `~`/工作目录之类的大目录开平铺（Recursive/Flat view）后，很多文件根本看不到。

**根因**：`BuildFlatListing()` 里写死了两个上限 —— 最多 100 万个条目、6.4 万个目录，超过就直接 `break`，
既没有提示也没有标记。用户那个目录树实测有 **1,637,209 个条目**，于是第 100 万条之后的目录（包括最深处的
100 万文件测试目录）全部没有出现在平铺列表里。

**修复**：

- 上限改为可配置：`filePanel.general.flatViewMaxItems`（默认 **1,000,000**）、
  `flatViewMaxDirectories`（默认 2,000,000）；
- 截断时不再整目录丢弃，而是按预算保留前面的条目（以前如果单个目录本身就超限，整个平铺列表会是空的）；
- 截断会**明确告知**：`Log::Warn` + 一个 sheet 提示（标题「平铺视图显示不完整」，正文说明只显示了前 N 项、
  以及用哪个设置项提高上限），字符串已加入 `Localizable.xcstrings` 的 en/ru/zh-Hans。

**验证**：

```
平铺 `/Volumes/Data/bench`（1,637,209 个条目）：
[perf] ui n=1637210 loadListing=221.9ms dataUpdated=34.1ms   → 全部条目都在
把 flatViewMaxItems 临时设成 100：列表恰好 100 项 + 弹出「平铺视图显示不完整」提示
```

代价：这种规模的平铺会在打开期间占用约 650 MB（1.6M 条目要物化成一个 listing），关闭平铺即释放。


### 33.1 跟进：平铺遍历会在第一个空目录处中断（且不弹提示）

上一版加"按预算截断"时把原来的

```cpp
if( wanted.empty() ) continue;   // 空目录：跳过继续走
```

改成了

```cpp
if( take == 0 ) break;           // ← 空目录也算 take == 0，于是整棵树的遍历在这里结束
```

后果：平铺在遇到的**第一个空目录**处停下，列表只有前面几个目录的内容，而且因为不是"超限截断"、
`truncated` 仍是 false，所以既不弹提示也没有日志——正是"文件没显示且没有弹窗"。

修复：空目录仍然 `continue`，只有预算耗尽（`wanted` 非空但 `take == 0`）才 `break`。

验证（`NC_PERF_LOG` 里新增的汇总行）：

```
[perf] flat root=/Volumes/Data/bench/ items=1637225 dirs=203817 truncated=0 listing=1
[perf] ui n=1637225 loadListing=196.2ms dataUpdated=35.2ms
```

即扫描了 203,817 个目录、163 万个条目，全部进入平铺列表；把 `flatViewMaxItems` 手动调成 100 时
仍然照旧弹"平铺视图显示不完整"的提示。


### 33.2 默认上限保持 100 万（按用户的意见）

`flatViewMaxItems` 的默认值最终定为 **1,000,000**（`flatViewMaxDirectories` 仍是 2,000,000），
理由是：这个规模内存可控（约 100 MB 的 listing），而且现在超限时**一定会弹提示**并告诉用户改哪个键，
不再是静默丢数据。

实测（默认配置，平铺 `/Volumes/Data/bench`）：

```
[perf] flat root=/Volumes/Data/bench/ items=1000000 dirs=82 truncated=1 listing=1
[perf] ui n=1000000 loadListing=154.1ms dataUpdated=42.1ms
```

面板底部显示 (1000000)，同时弹出「平铺视图显示不完整 / 此目录下的条目过多——只显示了前 1000000 项。
可以在设置项 filePanel.general.flatViewMaxItems 中提高上限。」——截图已确认。



## 附：平铺视图与搜索的后续工作

平铺视图的列式枚举、文件名/内容并行搜索，以及“能不能剥掉 VFS 层”的评估，都在
[Docs/VFS-Peel-Evaluation.md](VFS-Peel-Evaluation.md) 里。那里的结论是：这些加速来自算法与并行，
与语言无关；因此三块实现都用 C++ 落在 `Source/VFS/source/Native/Columnar.cpp` 与
`Source/NimbleCommander/NimbleCommander/Core/Parallel*.mm`，并由 `Scripts/perf/README.md` 里的开关控制。
