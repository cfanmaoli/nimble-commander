[English](Help.md) | 简体中文

# 快速入门

## 简介

Nimble Commander-Fork 是一款面向 macOS 的免费双栏文件管理器，注重速度、纯键盘操作体验与高度可定制性。
项目致力于将上世纪八九十年代经典文件管理器的高效交互，与现代 macOS 的原生观感融为一体。
Nimble Commander-Fork 遵循[正统文件管理器（Orthodox File Managers）](https://en.wikipedia.org/wiki/File_manager#Orthodox_file_managers)的设计理念，特别是经典的双栏布局。
如果你想深入了解这类软件的设计哲学，可以参考这篇文章：[Less is More: Orthodox File Managers as Sysadmin IDE](https://softpanorama.org/OFM/index.shtml)。

## 系统要求

当前版本的 Nimble Commander-Fork 支持运行以下任意 macOS 版本的 Apple Silicon Mac：

- macOS 27 Golden Gate
- macOS 26 Tahoe
- macOS 15 Sequoia
- macOS 14 Sonoma
- macOS 13 Ventura

维护目标是持续支持近几代主流 macOS 系统。

Nimble Commander-Fork 2.0 及以上版本仅原生支持 Apple Silicon（ARM64）Mac。

各版本兼容性对照表如下：

| 版本           | 架构        | 最低 macOS 版本         |
| -------------- | ----------- | ----------------------- |
| 2.0+           | ARM64       | macOS 13 Ventura        |
| 1.9.0 - 1.9.3c | x64 & ARM64 | macOS 12 Monterey       |
| 1.8.0          | x64 & ARM64 | macOS 11 Big Sur        |
| 1.2.9 - 1.7.0  | x64 & ARM64 | macOS 10.15 Catalina    |
| 1.2.0 - 1.2.7  | x64         | OS X 10.11 El Capitan   |
| 1.1.0 - 1.1.5  | x64         | OS X 10.10 Yosemite     |
| 1.0.7 - 1.0.9  | x64         | OS X 10.9 Mavericks     |
| 1.0.5 - 1.0.6  | x64         | OS X 10.8 Mountain Lion |
| 0.1.0 - 1.0.4  | x64         | Mac OS X 10.7 Lion      |

## 安装

Nimble Commander-Fork 是绿色便携应用，不需要安装额外组件，可从任意目录运行。
本分支仅提供独立的 Apple Silicon（ARM64）版本，将 `.dmg` 中的应用图标拖入 `/Applications`（应用程序）文件夹即可完成安装，也可以直接从 `.dmg` 镜像中运行。

![从 DMG 复制 Nimble Commander-Fork](Help-install-dmg.png)

## 启动应用

双击 Nimble Commander-Fork 图标即可启动。

由于本分支发布包未经过 Apple 公证（Notarisation），首次启动从网络下载的版本时 macOS 可能会拦截。你可以在「系统设置 → 隐私与安全性」中点击「仍要打开」，或在核对 Release 页面的 SHA-256 校验值后执行以下命令移除隔离属性：

```sh
xattr -dr com.apple.quarantine "/Applications/Nimble Commander-Fork.app"
```

## 访问权限

在 macOS 上访问特定受保护位置需要授予系统权限，包括：

- 桌面文件夹（Desktop）
- 文稿文件夹（Documents）
- 下载文件夹（Downloads）
- 可移动宗卷（Removable Volumes）
- 网络宗卷（Network Volumes）
- iCloud 云盘（iCloud Drive）

你可以在「系统设置 → 隐私与安全性 → 文件与文件夹」中按需授权，也可以在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中直接授予完全磁盘访问权限。

## 版本差异与构建类型

本分支仅提供单一的独立非沙盒版本（参见 [Building.md](Building.md)），不包含上游的 Mac App Store 沙盒版。因此管理员模式（Admin Mode）、内置终端、网络共享和 F1..F19 功能键均不受沙盒限制。

- **正式版（Stable Release）**：发布在 [GitHub Releases](https://github.com/cfanmaoli/nimble-commander/releases)，使用维护者的 Apple Development 证书（团队 `359W39ZS37`）与强化运行时（Hardened Runtime）签名，**支持管理员模式**；但未经公证，首次启动需手动放行。应用内自动检查更新（Sparkle）通过 `appcast.xml` 跟踪正式版。
- **每日构建（Nightly 预发布版）**：由 CI 构建，未签名且未公证；由于 macOS 仅允许已签名的应用加载特权守护进程，未签名构建无法启用管理员模式。签名详情参见 [Release.md](Release.md)。

## 管理员模式（Admin Mode）

管理员模式通过内嵌在应用包中的 `SMAppService` 守护进程（`Contents/Library/LaunchDaemons/info.filesmanager.Files.PrivilegedIOHelperV3.plist`）执行需要 root 权限的文件系统操作（例如浏览/修改仅 root 可访问的目录、修改所有者/系统标志或向其他用户的进程发送信号）。

- 开关路径：菜单栏 `Nimble Commander-Fork > 开启管理员模式`（`Turn Admin Mode On`）/ `关闭管理员模式`。
- 首次开启时，macOS 会提示你在「系统设置 → 通用 → 登录项与扩展」中允许 **Nimble Commander-Fork**，并进行管理员身份认证。
- 开启管理员模式后，应用会**优先尝试当前进程直接执行 POSIX I/O**，仅在遇到 `EACCES` 或 `EPERM` 权限拒绝时才提权转发给特权守护进程。因此，桌面、下载、文稿与可移动磁盘中的普通文件无需开启「完全磁盘访问权限」即可正常读写和打开（如 RAR 等压缩包）；只有在需要以管理员身份操作位于 TCC 受保护目录中且仅 root 可访问的文件时，才需要额外授予完全磁盘访问权限。

## 语言包与设置导入

- **语言包**（`偏好设置 > 语言` / `Preferences > Language`）：内置英文、俄文和简体中文界面，并支持导出当前语言、翻译后重新导入自定义语言包。社区维护的多语言包可在 [nc-language](https://github.com/cfanmaoli/nc-language) 获取。
- **导入原版设置**（`偏好设置 > 通用 > 导入设置` / `Preferences > General > Import Settings`）：可从原版 Nimble Commander 一键导入偏好设置、已保存标签页、网络连接、语言包与语法高亮配置。

# 文件面板

## 简介
以下是 Nimble Commander-Fork 的典型界面截图：

![界面示例](Help-main-ui.png)

主窗口通常垂直拆分为左右两个面板（下文有时也称“栏”或“窗格”）。
同一时间只有一个面板处于激活状态，并以高亮样式标示。
点击目标面板或使用以下快捷键即可切换激活面板：

- `Tab`：切换到另一侧面板
- `Shift + Cmd + Left`：聚焦左侧面板
- `Shift + Cmd + Right`：聚焦右侧面板

拖动中间的垂直分隔条，或按 `Ctrl + Opt + Left` / `Ctrl + Opt + Right` 可调整左右面板宽度比例。
你也可以将分隔条拖到边缘，或按 `Shift + Cmd + P` 在双栏模式与单栏模式之间切换。

每个面板在纵向上分为三个区域：

- 顶部栏（Header）：显示当前路径及排序方式指示符。
- 文件列表区：展示当前目录下的所有条目。
- 底部状态栏（Footer）：显示当前焦点条目的文件名、大小、修改时间、面板总条目数以及当前卷的可用空间。

## 导航
Nimble Commander-Fork 同时支持鼠标与键盘操作，并优先为键盘流优化。
单击条目可移动光标（改变当前焦点项），滚动手势可在不改变光标位置的情况下浏览列表。
常用导航快捷键如下：

- `Up`：光标上移
- `Down`：光标下移
- `Left`：光标左移
- `Right`：光标右移
- `Home`：光标移至首项
- `Opt + Home`：视图滚动至首项
- `End`：光标移至末项
- `Opt + End`：视图滚动至末项
- `Page Up`：光标上翻一页
- `Opt + Page Up`：视图上翻一页
- `Page Down`：光标下翻一页
- `Opt + Page Down`：视图下翻一页

双击文件夹或在焦点位于文件夹上时按 `Return` 即可进入该目录。
对列表顶部的 `..` [伪目录](https://en.wikipedia.org/wiki/Path_(computing)#Representations_of_paths_by_operating_system_and_shell)执行相同操作可返回上级目录（可在 `偏好设置` 中选择是否显示 `..`）。
无论光标位于何处，按 `Backward Delete`（退格键）或 `Cmd + Up` 都可直接返回上级目录。

每个面板都独立维护访问历史，按 `Cmd + [` 和 `Cmd + ]` 可后退或前进。

常用目录跳转快捷键：

- `/`：文件系统根目录
- `~`（`Shift + ~`）或 `Shift + Cmd + H`：个人主目录（Home）
- `Shift + Cmd + O`：文稿（Documents）
- `Shift + Cmd + D`：桌面（Desktop）
- `Opt + Cmd + L`：下载（Downloads）
- `Shift + Cmd + A`：应用程序（Applications）
- `Shift + Cmd + U`：实用工具（Utilities）
- `Opt + Cmd + P`：进程列表

按 `F1` / `F2` 或通过菜单 `前往 > 左侧面板...` / `前往 > 右侧面板...` 可唤出「前往（Go To）」弹窗，快速访问收藏夹、已挂载宗卷、网络连接和其他窗口中的路径。
弹窗中的条目按出现顺序依次绑定快捷键：`1`、`2`、……、`9`、`0`、`-`、`=`。
弹窗打开时直接输入文字即可实时过滤名称，选中后目标面板会自动跳转并获取焦点：

![前往弹窗](Help-goto-popup.png)

按 `Shift + Cmd + G` 或选择菜单 `前往 > 前往文件夹...` 可输入任意路径直接跳转：

![前往文件夹对话框](Help-goto-dialog.png)

当光标位于符号链接（symlink）上时，按 `Cmd + Right`（`前往 > 追踪符号链接`）可跳转到链接指向的实际位置。

## 打开项目
按下 `Return` 键会根据条目类型执行对应操作：

- 普通文件夹：进入该文件夹。
- 压缩包文件：直接以虚拟文件系统方式打开并进入其根目录。
- 可执行文件：在内置终端模拟器中运行该文件。
- 其他文件：使用 macOS 默认关联应用打开。

如果需要进入非标准扩展名的压缩包（如 `.xlsx`、`.pak` 等），可按 `Cmd + Down` 或选择菜单 `前往 > 进入文件夹` 强制按压缩包方式打开。

按 `Shift + Return` 可忽略条目类型，始终以 macOS 默认方式打开。

如需使用指定外部应用打开，可在右键上下文菜单或 `文件` 菜单中选择 `打开方式（Open With）`。

## 面板管理
- 互换左右面板内容并切换焦点：`Cmd + U` 或 `显示 > 互换面板`。
- 将对侧面板同步到当前面板路径：`Opt + Cmd + U` 或 `显示 > 同步面板`。
- 手动刷新列表（在文件系统变化未能自动感知时使用）：`Cmd + R` 或 `显示 > 刷新`。

左右面板默认等宽，拖动分隔线或按 `Ctrl + Opt + Left` / `Ctrl + Opt + Right` 可自由调整比例：

![调整面板比例](Help-panel-proportion.png)

按 `Shift + Cmd + P` 或选择 `显示 > 切换双栏/单栏模式` 可折叠一侧面板进入单栏模式，再按一次即可恢复双栏：

![单栏模式](Help-panel-collapsed.png)

## 选择条目
Nimble Commander-Fork 采用正统文件管理器的交互逻辑，将**选择状态**与**光标焦点**分离——移动光标不会取消已选中的条目。下图展示了选中部分条目、同时光标停留在未选中项上的效果：

![选择条目](Help-panel-selection.png)

常用选择方式：

- `Cmd + A`：全选。
- `Opt + Cmd + A`：取消全选。
- `Ctrl + Cmd + A`：反选。
- `Shift + Up` / `Shift + Down`：反转当前焦点项的选中状态并移动光标（按下 `Shift` 时的初始动作会在按住期间保持一致）。
- `Shift + 光标移动键`：批量切换从起点到终点范围内所有条目的选中状态。
- `Enter`（小键盘 `Enter` 或笔记本 `Fn + Return`，区别于主键盘 `Return`）：反选当前焦点项并将光标移至下一项。
- `Cmd + 单击`：切换被点击条目的选中状态。
- `Cmd + =`：按文件名通配符或正则表达式选中匹配条目。
- `Cmd + -`：按文件名通配符或正则表达式取消选中匹配条目。
- `Opt + Cmd + =`：选中与当前焦点项扩展名相同的所有条目。
- `Opt + Cmd + -`：取消选中与当前焦点项扩展名相同的所有条目。

## 排序方式
支持按以下属性升序或降序排列：

- 名称（Name）
- 扩展名（Extension）
- 大小（Size）
- 修改时间（Modified Time）
- 创建时间（Created Time）
- 添加时间（Added Time）
- 访问时间（Accessed Time）

面板左上角的字母指示符表示当前排序方式：

| 指示符 | 排序依据 | 顺序 | 示例            |
| ------ | -------- | ---- | --------------- |
| `n`    | 名称     | 升序 | a ... z         |
| `N`    | 名称     | 降序 | z ... a         |
| `e`    | 扩展名   | 升序 | csv ... zip     |
| `E`    | 扩展名   | 降序 | zip ... csv     |
| `s`    | 大小     | 降序 | 10 MB ... 1 MB  |
| `S`    | 大小     | 升序 | 1 MB ... 10 MB  |
| `m`    | 修改时间 | 降序 | 20:43 ... 18:15 |
| `M`    | 修改时间 | 升序 | 18:15 ... 20:43 |
| `b`    | 创建时间 | 降序 | 20:43 ... 18:15 |
| `B`    | 创建时间 | 升序 | 18:15 ... 20:43 |
| `a`    | 添加时间 | 降序 | 20:43 ... 18:15 |
| `A`    | 添加时间 | 升序 | 18:15 ... 20:43 |
| `x`    | 访问时间 | 降序 | 20:43 ... 18:15 |
| `X`    | 访问时间 | 升序 | 18:15 ... 20:43 |

点击左上角指示符可弹出排序菜单：

![排序弹出菜单](Help-panel-sorting.png)

你也可以通过 `显示 > 排序`、列表视图中的列标题，或以下快捷键切换排序（重复按下同一排序依据会切换升/降序）：

- `Ctrl + Cmd + 1`：按名称排序
- `Ctrl + Cmd + 2`：按扩展名排序
- `Ctrl + Cmd + 3`：按修改时间排序
- `Ctrl + Cmd + 4`：按大小排序
- `Ctrl + Cmd + 5`：按创建时间排序
- `Ctrl + Cmd + 6`：按添加时间排序
- `Ctrl + Cmd + 7`：按访问时间排序

进阶排序选项：

- `文件夹与文件分开`（`Separate Folders from Files`）：所有文件夹排在普通文件之前。
- `忽略文件夹扩展名`（`Extensionless Folders`）：按扩展名排序时将文件夹视为无扩展名。
- `比较方式`（`Comparison`）：
  - `自然排序（Natural）`：遵循区域排序规则并将数字按数值大小比较，与访达一致，速度最慢。
  - `不区分大小写（Case-Insensitive）`：基于 Unicode 忽略大小写比较。
  - `区分大小写（Case-Sensitive）`：逐字符直接比较，速度最快。

## 隐藏项目
文件名以点（`.`）开头或带有系统隐藏属性（`UF_HIDDEN`）的条目视为隐藏项目（上级目录 `..` 永远不被隐藏）。
默认不显示隐藏项目，按 `Shift + Cmd + .` 或选择 `显示 > 显示隐藏文件` 即可切换显示状态。

## 快速搜索（Quick Search）
在面板中直接键入文件名片段即可快速定位或过滤文件，按 `Esc` 清除搜索条件。

在 `偏好设置 > 面板 > 快速搜索` 中可以设置匹配时的显示模式（`显示所有项目` 或 `仅显示匹配项目`）：

![快速搜索](Help-panel-quicksearch.png)

可配置的触发修饰键（`Key modifier`）：

- `Opt`
- `Ctrl + Opt`
- `Shift + Opt`
- `无修饰键`（默认）
- `禁用`（彻底关闭快速搜索）

可配置的匹配位置（`Where to search`）：

- `模糊匹配（Fuzzy）`：输入字符按顺序出现在文件名任意位置即可。
- `任意位置（Anywhere）`（默认）：输入字符串完整出现在文件名任意位置。
- `开头（Beginning）`：文件名以输入字符串开头。
- `结尾（Ending）`：文件名以输入字符串结尾。
- `开头或结尾（Beginning or ending）`：文件名以输入字符串开头或结尾。

当设置为「显示所有项目」且启用了修饰键时，按住该修饰键再使用方向键、`Home`、`End` 等键可将光标移动锁定在匹配项之间。

## 视图模式
支持三种面板展示模式：简洁（Brief）、列表（List）和画廊（Gallery）。

- **简洁模式（Brief）**：仅显示文件名、图标和标签颜色，按多列紧凑排布，支持上下左右移动光标。
- **列表模式（List）**：表格化展示每项的详细属性，仅上下移动光标。
- **画廊模式（Gallery）**：底部横向排列带名称的图标，上方提供当前焦点项的交互式快速查看（Quick Look）预览。

下图展示了同一目录 `/usr/bin` 在简洁模式与列表模式下的对比：

![简洁与列表模式](Help-panel-modes.png)

下图展示了折叠对侧面板后的画廊模式：

![画廊模式](Help-panel-gallery.png)

默认预置 5 种视图模式，可通过 `显示 > 视图模式` 或快捷键切换：

- `Ctrl + 1` - `精简（Short）`：3 等宽列的简洁模式。
- `Ctrl + 2` - `中等（Medium）`：根据文件名自动调整列宽的简洁模式。
- `Ctrl + 3` - `完整（Full）`：包含名称、大小、创建时间、修改时间、添加时间的列表模式。
- `Ctrl + 4` - `宽列（Wide）`：包含名称和大小两列的列表模式。
- `Ctrl + 5` - `画廊（Gallery）`：图标搭配双行文件名的画廊模式。

在 `偏好设置 > 面板 > 布局` 中可自定义、重排并新增最多 10 套面板视图布局。

## 平铺视图（Flat View）

平铺视图会将当前目录下所有层级的文件和文件夹展开到同一个面板中，适合在深层目录树中集中浏览、筛选或批量操作文件，而无需反复进出子目录。

通过 `显示 > 平铺视图` 或 `Opt + Cmd + B` 开启/关闭。平铺状态下路径栏仍显示起始目录，关闭平铺视图或跳转到其他位置即恢复正常目录视图。指向目录的符号链接仅列出而不递归追踪，同时内置遍历上限以防超大型目录树阻塞面板。

## 快速列表（Quick Lists）
快速列表用于在当前面板内以最少按键直达特定分类的位置。通过 `前往 > 快速列表` 或以下快捷键唤出：

- `Cmd + 1` - `上级文件夹（Parent Folders）`：逐级向上直到根目录。
- `Cmd + 2` - `历史记录（History）`：当前面板近期访问过的位置。
- `Cmd + 3` - `收藏夹（Favorites）`：收藏与高频访问位置。
- `Cmd + 4` - `宗卷（Volumes）`：当前挂载的磁盘宗卷。
- `Cmd + 5` - `连接（Connections）`：已保存的网络连接，点击即可建立连接并进入默认目录。
- `Cmd + 6` - `标签（Tags）`：已知访达标签列表，点击后将所有带该标签的项目汇总显示在面板中。

下图为 `宗卷` 快速列表示例：

![快速列表](Help-panel-quicklist.png)

## 标签页（Tabs）
左右面板均支持多标签页。当单侧打开超过一个标签页时会自动显示标签栏；按 `Shift + Cmd + T` 或通过 `显示 > 显示/隐藏标签栏` 可强制常驻显示：

![多标签页界面](Help-panel-tabs.png)

新建与恢复标签页：

- `Cmd + T`（`文件 > 新建标签页`）：以当前路径新建标签页。
- 点击标签栏旁的 `+` 按钮（长按或右键可查看最近关闭的位置列表）。
- `Shift + Cmd + R`：恢复最近关闭的标签页并激活。
- `Opt + Cmd + Return`：在对侧面板的新标签页中显示当前焦点项。

切换标签页：

- `Shift + Cmd + ]` 或 `Ctrl + Tab`：下一个标签页。
- `Shift + Cmd + [` 或 `Ctrl + Shift + Tab`：上一个标签页。
- 可在 `偏好设置 > 快捷键` 中为 `Show Tab №1..№10` 绑定直达指定标签页的快捷键。

关闭标签页：

- `Cmd + W`：关闭当前标签页。
- `Opt + Cmd + W`：关闭其他所有标签页。

## 收藏夹（Favorites）
可通过以下入口快速访问收藏位置：

- 菜单 `前往 > 收藏夹`。
- 前往弹窗（`F1` / `F2`）。
- 收藏夹快速列表（`Cmd + 3`）。

按 `Ctrl + Cmd + B` 或选择 `前往 > 收藏夹 > 管理收藏夹...` 可打开收藏夹管理窗口，支持增删位置或恢复默认集合；也可在面板中直接按 `Cmd + B`（`文件 > 添加到收藏夹`）将当前位置加入收藏。收藏项既可以是本地路径，也可以是网络文件系统、压缩包内部、扩展属性或进程列表等任意虚拟文件系统位置：

![收藏夹窗口](Help-panel-favorites.png)

## 搜索文件
按 `Cmd + F` 或选择 `文件 > 查找...` 打开文件查找对话框，递归搜索符合条件的条目：

![查找文件](Help-panel-findfiles.png)

支持的搜索条件：

- **文件名匹配**：支持通配符与正则表达式。
- **内容搜索**：查找包含或不包含指定文本的文件，可配置大小写敏感、整词匹配及文本编码。
- **文件大小**：按小于、等于或大于指定大小筛选。

搜索结果支持：

- 在不关闭对话框的情况下直接用内置查看器预览选中文件。
- 跳转到该文件所在目录（自动关闭对话框）。
- 将全部结果输出到临时文件面板（Panelize）以便继续批量操作。

# 文件操作

## 简介
Nimble Commander-Fork 会尽可能在后台执行文件操作，保持界面流畅响应。
多数操作绑定在发起窗口内，进度条显示在窗口顶部中央，支持随时暂停或取消：

![文件操作进度](Help-file-operations.png)

## 复制（Copy）
- `F5`（`命令 > 复制到...`）：打开复制对话框，默认目标为对侧面板，可选择保留哪些文件属性以及是否启用 SHA-256 校验。
- `Shift + F5`（`命令 > 另存复制到...`）：预填原文件名，便于快速改名复制。
- `Cmd + V`：将剪贴板中的文件路径复制到当前激活面板目录。
- 按住 `Opt` 键拖动：将选中项复制到目标位置。

## 制作副本（Duplicate）
按 `Cmd + D` 或选择 `文件 > 制作副本` 在当前目录内直接复制选中项。

## 移动（Move）
- `F6`（`命令 > 重命名/移动到...`）：打开移动对话框，跨文件系统移动时同样可配置属性保留与 SHA-256 校验。
- `Shift + F6`（`命令 > 重命名/移动为...`）：预填原文件名，便于改名或移入子目录。
- `Opt + Cmd + V`：将剪贴板中的文件移动到当前激活面板目录。
- 直接鼠标拖动：将选中项移动到目标位置。

## 就地重命名（Rename）
单击文件名或按 `Ctrl + F6`（`命令 > 就地重命名`）即可直接编辑文件名。

## 批量重命名（Batch Rename）
选中多个条目后按 `Ctrl + M` 或选择 `命令 > 批量重命名...` 打开批量重命名对话框：

![批量重命名](Help-batch-rename.png)

重命名分为三个步骤：

  1. 拆解原文件名并用占位符模板组合出新名称。
  2. （可选）查找并替换名称中的指定文本。
  3. （可选）转换字母大小写。

占位符语法如下：

  - 基于原文件名：
    - `[N]`：不含扩展名的文件名（如 `example.txt` → `example`）。
    - `[E]`：扩展名（如 `example.txt` → `txt`）。
    - `[A]`：完整文件名（如 `example.txt` → `example.txt`）。
    - `[P]`：父文件夹名（如 `Parent/example.txt` → `Parent`）。
    - `[G]`：祖父文件夹名（如 `Grandparent/Parent/example.txt` → `Grandparent`）。
    - 以上占位符均支持子串切片：
      - `[Nx]`：第 **x** 个字符。  
        `example.txt → [N4] → m`
      - `[Nx-y]`：第 **x** 到第 **y** 个字符。  
        `example.txt → [N2-4] → xam`
      - `[Nx,y]`：从第 **x** 个位置起取 **y** 个字符。  
        `example.txt → [N5,2] → pl`
      - `[Nx-]`：从第 **x** 个位置到末尾。  
        `example.txt → [N5-] → ple`
      - `[N0x-y]`：第 **x** 到第 **y** 个字符，不足位左侧补零。  
        `example.txt → [N05-10] → 000ple`
      - `[N x-y]`：第 **x** 到第 **y** 个字符，不足位左侧补空格。  
        `example.txt → [N 5-10] → ␣␣␣ple`
      - `[N-x,y]`：从倒数第 **x** 个位置起取 **y** 个字符。  
        `example.txt → [N-5,3] → amp`
      - `[N-x-y]`：从倒数第 **x** 到倒数第 **y** 个字符。  
        `example.txt → [N-5-2] → ampl`
      - `[Nx--y]`：从第 **x** 个到倒数第 **y** 个字符。  
        `example.txt → [N2--2] → xampl`
      - `[N-x-]`：从倒数第 **x** 个位置到末尾。  
        `example.txt → [N-4-] → mple`
  - 基于文件修改时间：
    - `[d]`：本地化日期（如 `07-12-2024`）。
    - `[Y]`：4 位年份（如 `2024`）。
    - `[y]`：2 位年份（如 `24`）。
    - `[M]`：2 位月份（如 `12`）。
    - `[D]`：2 位日期（如 `07`）。
    - `[t]`：本地化时间（如 `13.58`）。
    - `[h]`：24 小时制 2 位小时（如 `13`）。
    - `[m]`：2 位分钟（如 `58`）。
    - `[s]`：2 位秒数（如 `43`）。
  - 基于计数器：
    - `[C]`：使用对话框中的默认计数设置。  
      `[C] → 1, 2, 3, 4, 5...`
    - `[Cx]`：从 **x** 开始计数。  
      `[C5] → 5, 6, 7, 8, 9...`
    - `[Cx+y]`：从 **x** 开始，步长为 **y**。  
      `[C5+5] → 5, 10, 15, 20, 25...`
    - `[Cx+y/z]`：从 **x** 开始，步长 **y**，每 **z** 项递增一次。  
      `[C5+5/2] → 5, 5, 10, 10, 15...`
    - `[Cx+y/z:w]`：同上，并补零至 **w** 位宽度。  
      `[C5+5/2:3] → 005, 005, 010, 010, 015...`
    - 各自定义参数均可省略，例如 `[C:w]`、`[C+y:w]` 均有效。
  - 大小写转换指令：
    - `[U]`：后续文本转为全大写。
    - `[L]`：后续文本转为全小写。
    - `[F]`：后续文本每个单词首字母大写。
    - `[n]`：恢复原始大小写。
  - 其他占位符：
    - `[[`：插入字面左方括号 `[`。
    - `]]`：插入字面右方括号 `]`。

对话框会实时预览重命名结果，只有在点击 `确定` 或按 `Cmd + Return` 后才会实际执行。

## 删除与废纸篓
- 按 `Cmd + Backward Delete`（`命令 > 移到废纸篓`）将选中项移入废纸篓；如果当前卷不支持废纸篓，将弹出永久删除确认框。
- 按 `F8`（`命令 > 删除...`）或 `Shift + F8`（`命令 > 永久删除...`）打开删除对话框，两者的区别在于默认选项不同。右键菜单中按住 `Opt` 会以红色高亮显示「永久删除」。
- 通过 `前往 > 废纸篓` 可直接浏览废纸篓，使用 `命令 > 放回原处`（`Put Back`）还原文件，或通过 `命令 > 清倒废纸篓…` 清空（为防误触，该命令默认不绑定快捷键）。

## 创建文件夹
- `F7`（`命令 > 新建目录...`）：弹窗输入目录名后再创建，支持一次创建多级嵌套目录（例如 `New 1/New 2/New 3`）。按 `Shift + F7`（`命令 > 在对侧面板新建目录...`）可在对侧面板创建。
- `Shift + Cmd + N`（`文件 > 新建文件夹`）：立即创建一个临时命名的空文件夹并进入就地重命名状态。

## 创建文件
按 `Opt + Cmd + N` 或选择 `文件 > 新建文件`，立即创建一个空文件并进入就地重命名状态。

## 修改属性
按 `Ctrl + A` 或选择 `命令 > 文件属性` 打开属性编辑对话框：

![修改文件属性](Help-attr-change.png)

可查看并批量修改权限、系统标志、所有者与时间戳；多选条目存在差异时对应复选框会呈不确定状态。选中文件夹时支持递归应用到所有子项。部分属性修改需要开启管理员模式。

## 压缩
内置压缩工具支持 **ZIP**、**7z** 与 **tar** 格式，可在 `偏好设置 > 压缩` 中选择默认容器、压缩方式和压缩级别。仅 ZIP 支持密码保护（AES-256），选择其他格式时密码选项自动禁用。

- `F9`（`命令 > 压缩...`）：在当前目录创建压缩包。
- `Shift + F9`（`命令 > 压缩到...`）：在对侧面板目录创建压缩包。

## 管理链接
通过 `命令 > 链接` 菜单可创建硬链接、创建或编辑符号链接（默认无快捷键）：

- `创建硬链接`
- `创建符号链接`
- `编辑符号链接`

# 虚拟文件系统（VFS）
除本地 macOS 文件系统外，Nimble Commander-Fork 还允许像浏览普通目录一样操作多种虚拟资源，包括浏览、搜索、查看与写入（若该 VFS 支持写入）。
使用外部应用打开 VFS 中的文件时，会先自动复制到临时位置（大文件会弹出确认提示）；若该 VFS 可写，外部编辑器保存修改后会自动回传同步。

当前支持的虚拟文件系统：

- **压缩包与归档文件**  
  支持 `ar`、`bz2`、`bzip2`、`cab`、`cpgz`、`cpio`、`gz`、`gzip`、`iso`、`jar`、`lha`、`lz`、`lzma`、`lzo`、`lz4`、`mtree`、`pax`、`rar`、`tar`、`xar`、`xz`、`z`、`zip`、`zst`、`7z`。
  压缩包以只读方式打开，内部路径以压缩包自身路径作为前缀。
  如需完整的 RAR 支持（固实压缩、加密文件头/内容及分卷压缩包），可安装可选的 `ncrar-helper` 组件并在 `偏好设置 > 压缩` 中管理，详见 [RarSupport.md](RarSupport.md)。
- **网络协议**
  - **FTP**：连接 FTP 服务器（`ftp://` 前缀）。
  - **SFTP**：通过 SSH 文件传输协议连接（`sftp://` 前缀）。
  - **WebDAV**：连接 WebDAV 服务器（`http://` 或 `https://` 前缀）。
  - **网络共享**：通过 macOS NetFS 挂载 SMB/AFP/NFS 网络共享。
- **扩展属性（Extended Attributes）**  
  按 `Opt + Cmd + X` 或选择 `命令 > 打开扩展属性`，以可读写文件夹的形式查看与编辑文件的 [扩展属性（xattrs）](https://en.wikipedia.org/wiki/Extended_file_attributes#macOS)。
- **进程列表**  
  按 `Opt + Cmd + P` 或选择 `前往 > 进程列表`，以文件形式列出当前运行的所有进程并展示文本详情；删除其中的条目即可终止对应进程。

# 外部编辑器
在 `偏好设置 > 编辑器` 中配置外部编辑器列表。
按 `F4` 或选择 `命令 > 外部编辑器`，应用会根据当前焦点文件的扩展名/通配符自动匹配对应编辑器并打开。
外部编辑器既可以是独立 macOS 图形应用，也可以是在内置终端中运行的命令行编辑器（如 `vi`）。

# 外部工具（Tools）
与外部编辑器类似，但允许完全自定义启动参数，并可绑定快捷键或添加到工具栏。配置入口：`偏好设置 > 工具`。

触发方式：

- 按下已配置的快捷键。
- 点击工具栏上的对应图标。
- 从 `命令 > 工具` 菜单中选择。

外部工具仅在面板位于本地 macOS 文件系统路径时可用，不支持在虚拟文件系统（VFS）中运行。

运行模式（`Startup Mode`）：

- `独立运行（Run Detached）`：作为独立 macOS 应用启动。
- `在终端中运行（Run in Terminal）`：在内置终端模拟器中执行命令行工具。

支持的参数占位符：

- 插入当前焦点项：
  - 来自源（当前）面板：
    - `%p`：条目完整路径。
    - `%f`：文件名。
    - `%n`：不含扩展名的文件名。
    - `%e`：扩展名。
    - `%r`：当前面板路径。
  - 来自目标（对侧）面板：
    - `%-p`：条目完整路径。
    - `%-f`：文件名。
    - `%-n`：不含扩展名的文件名。
    - `%-e`：扩展名。
    - `%-r`：对侧面板路径。
- 插入已选中项：
  - 来自源（当前）面板：
    - `%P`：所有选中项路径作为参数传入。
    - `%xP`：同上，最多传 **x** 个文件。
    - `%LP`：将所有选中项路径写入临时文本文件并传入该文件路径。
    - `%xLP`：同上，最多 **x** 个文件。
    - `%F`：所有选中项文件名作为参数传入。
    - `%xF`：同上，最多 **x** 个文件。
    - `%LF`：将所有选中项文件名写入临时文本文件并传入该文件路径。
    - `%xLF`：同上，最多 **x** 个文件。
  - 来自目标（对侧）面板：
    - `%-P` / `%-xP` / `%-LP` / `%-xLP` / `%-F` / `%-xF` / `%-LF` / `%-xLF`（含义同上，取自对侧面板）。
- 执行时交互式询问参数：
  - `%?`：弹窗询问参数值。
  - `%"提示语"?`：以自定义**提示语**弹窗询问参数值。
- 其他占位符：
  - `%%`：插入字面 `%` 字符。
  - `%-`：在「源/目标面板」与「左/右面板」语义之间切换。
  - `%xT`：将传给工具的文件总数上限设为 **x**。

# 内置查看器（Integrated Viewer）
内置查看器让你无需离开应用即可快速检查任意文件内容：

![内置查看器](Help-intergrated-viewer.png)

同时支持本地文件与虚拟文件系统（例如无需解压即可直接查看压缩包里的文件）。
查看超大文件时仅按窗口分块加载，保持极低内存占用。
如果文件在查看期间被外部修改，内容会自动刷新；当滚动到文件末尾（例如实时写入的日志）时会自动跟随新追加的内容。

支持三种查看模式：

- **文本模式（`Cmd + 1`）**：按选定编码显示文本，并根据文件扩展名自动应用语法高亮。
- **十六进制模式（`Cmd + 2`）**：每行 16 字节，包含偏移量、两组 8 字节十六进制数据及文本解码预览。
- **预览模式（`Cmd + 3`）**：调用系统 Quick Look 进行图形化预览。

可在 `偏好设置 > 查看器` 中选择嵌入当前主窗口或以独立浮动窗口打开。
按 `F3`（`命令 > 内置查看器`）打开，按 `Esc` 关闭。

# 内置终端（Integrated Terminal）
内置终端模拟器支持主流 VT100 控制序列、256 色和鼠标交互：

![内置终端](Help-terminal.png)

终端具备路径上下文感知能力，与当前文件面板双向同步：在终端中执行 `cd` 会同步切换面板目录，在面板中切换目录也会同步更新终端工作目录。
支持的 Shell 包括 `bash`、`zsh`、`csh` 和 `tcsh`。

提供两种使用方式：

- **全窗口模式**：终端占据整个窗口，临时隐藏文件面板。按 `Opt + Cmd + O` 或选择 `显示 > 显示/隐藏终端` 切换。
- **叠层模式（Overlapped Mode）**：终端位于文件面板下方，两者可同时显示。按 `Ctrl + Opt + Up` 上移面板露出终端，按 `Ctrl + Opt + Down` 收起，按 `Ctrl + Opt + O` 完整隐藏或恢复面板。也可在 `偏好设置 > 面板 > 行为` 中开启“将键盘输入重定向到叠层终端”。

# 快捷键一览
以下为默认快捷键，均可在 `偏好设置 > 快捷键` 中自由修改（单个动作最多可绑定 4 组快捷键）。快捷键列为空的操作默认未绑定快捷键，可通过菜单调用或自行设置。

| 操作                                         | 默认快捷键                |
| -------------------------------------------- | ------------------------- |
| _**Nimble Commander-Fork 菜单**_             |                           |
| &nbsp; 关于 Nimble Commander-Fork            |                           |
| &nbsp; 偏好设置…                             | Cmd + ,                   |
| &nbsp; 开启 / 关闭管理员模式                 |                           |
| &nbsp; 隐藏 Nimble Commander-Fork            | Cmd + H                   |
| &nbsp; 隐藏其他                              | Opt + Cmd + H             |
| &nbsp; 全部显示                              |                           |
| &nbsp; 退出 Nimble Commander-Fork            | Cmd + Q                   |
| _**文件（File）菜单**_                       |                           |
| &nbsp; 新建窗口                              | Cmd + N                   |
| &nbsp; 新建文件夹                            | Shift + Cmd + N           |
| &nbsp; 用所选项目新建文件夹                  | Ctrl + Cmd + N            |
| &nbsp; 新建文件                              | Opt + Cmd + N             |
| &nbsp; 新建标签页                            | Cmd + T                   |
| &nbsp; 进入（Enter）                         | Return                    |
| &nbsp; 打开（Open）                          | Shift + Return            |
| &nbsp; 在对侧面板中显示                      | Opt + Return              |
| &nbsp; 在对侧面板新标签页中显示              | Opt + Cmd + Return        |
| &nbsp; 将文件名粘贴到终端                    | Ctrl + Opt + Return       |
| &nbsp; 将多个文件名粘贴到终端...             | Ctrl + Opt + Cmd + Return |
| &nbsp; 计算文件夹大小                        | Shift + Opt + Return      |
| &nbsp; 计算所有文件夹大小                    | Ctrl + Shift + Return     |
| &nbsp; 制作副本                              | Cmd + D                   |
| &nbsp; 添加到收藏夹                          | Cmd + B                   |
| &nbsp; 关闭标签页                            | Cmd + W                   |
| &nbsp; 关闭窗口                              | Shift + Cmd + W           |
| &nbsp; 关闭其他标签页                        | Opt + Cmd + W             |
| &nbsp; 查找...                               | Cmd + F                   |
| &nbsp; 查找下一个                            | Cmd + G                   |
| &nbsp; 使用聚焦（Spotlight）查找...          | Opt + Cmd + F             |
| _**编辑（Edit）菜单**_                       |                           |
| &nbsp; 拷贝                                  | Cmd + C                   |
| &nbsp; 粘贴                                  | Cmd + V                   |
| &nbsp; 将项目移到这里                        | Opt + Cmd + V             |
| &nbsp; 全选                                  | Cmd + A                   |
| &nbsp; 取消全选                              | Opt + Cmd + A             |
| &nbsp; 反选                                  | Ctrl + Cmd + A            |
| _**显示（View）菜单**_                       |                           |
| &nbsp; 切换双栏 / 单栏模式                   | Shift + Cmd + P           |
| &nbsp; 互换面板                              | Cmd + U                   |
| &nbsp; 同步面板                              | Opt + Cmd + U             |
| &nbsp; 刷新                                  | Cmd + R                   |
| &nbsp; _**视图模式子菜单**_                  |                           |
| &nbsp; &nbsp; 精简模式（Short）              | Ctrl + 1                  |
| &nbsp; &nbsp; 中等模式（Medium）             | Ctrl + 2                  |
| &nbsp; &nbsp; 完整模式（Full）               | Ctrl + 3                  |
| &nbsp; &nbsp; 宽列模式（Wide）               | Ctrl + 4                  |
| &nbsp; &nbsp; 画廊模式（Gallery）            | Ctrl + 5                  |
| &nbsp; &nbsp; 视图模式 VI..X                 | Ctrl + 6 .. Ctrl + 0      |
| &nbsp; _**排序子菜单**_                      |                           |
| &nbsp; &nbsp; 按名称排序                     | Ctrl + Cmd + 1            |
| &nbsp; &nbsp; 按扩展名排序                   | Ctrl + Cmd + 2            |
| &nbsp; &nbsp; 按修改时间排序                 | Ctrl + Cmd + 3            |
| &nbsp; &nbsp; 按大小排序                     | Ctrl + Cmd + 4            |
| &nbsp; &nbsp; 按创建时间排序                 | Ctrl + Cmd + 5            |
| &nbsp; &nbsp; 按添加时间排序                 | Ctrl + Cmd + 6            |
| &nbsp; &nbsp; 按访问时间排序                 | Ctrl + Cmd + 7            |
| &nbsp; &nbsp; 文件夹与文件分开               |                           |
| &nbsp; &nbsp; 忽略文件夹扩展名               |                           |
| &nbsp; &nbsp; 自然排序                       |                           |
| &nbsp; &nbsp; 不区分大小写比较               |                           |
| &nbsp; &nbsp; 区分大小写比较                 |                           |
| &nbsp; 显示隐藏文件                          | Shift + Cmd + .           |
| &nbsp; 平铺视图（Flat View）                 | Opt + Cmd + B             |
| &nbsp; _**面板位置子菜单**_                  |                           |
| &nbsp; &nbsp; 向左调整                       | Ctrl + Opt + Left         |
| &nbsp; &nbsp; 向右调整                       | Ctrl + Opt + Right        |
| &nbsp; &nbsp; 向上移动                       | Ctrl + Opt + Up           |
| &nbsp; &nbsp; 向下移动                       | Ctrl + Opt + Down         |
| &nbsp; &nbsp; 显示 / 隐藏面板                | Ctrl + Opt + O            |
| &nbsp; &nbsp; 聚焦叠层终端                   | Ctrl + Opt + Tab          |
| &nbsp; 显示 / 隐藏标签栏                     | Shift + Cmd + T           |
| &nbsp; 显示 / 隐藏工具栏                     | Opt + Cmd + T             |
| &nbsp; 显示 / 隐藏终端                       | Opt + Cmd + O             |
| _**前往（Go）菜单**_                         |                           |
| &nbsp; 左侧面板...                           | F1                        |
| &nbsp; 右侧面板...                           | F2                        |
| &nbsp; 后退                                  | Cmd + [                   |
| &nbsp; 前进                                  | Cmd + ]                   |
| &nbsp; 上层文件夹                            | Cmd + Up                  |
| &nbsp; 进入文件夹（强制进入压缩包）          | Cmd + Down                |
| &nbsp; 追踪符号链接                          | Cmd + Right               |
| &nbsp; 文稿                                  | Shift + Cmd + O           |
| &nbsp; 桌面                                  | Shift + Cmd + D           |
| &nbsp; 下载                                  | Opt + Cmd + L             |
| &nbsp; 个人主目录                            | Shift + Cmd + H           |
| &nbsp; 废纸篓                                |                           |
| &nbsp; 资源库                                |                           |
| &nbsp; 应用程序                              | Shift + Cmd + A           |
| &nbsp; 实用工具                              | Shift + Cmd + U           |
| &nbsp; 根目录                                |                           |
| &nbsp; 进程列表                              | Opt + Cmd + P             |
| &nbsp; _**收藏夹子菜单**_                    |                           |
| &nbsp; &nbsp; 管理收藏夹...                  | Ctrl + Cmd + B            |
| &nbsp; _**最近关闭子菜单**_                  |                           |
| &nbsp; &nbsp; 恢复关闭的标签页               | Shift + Cmd + R           |
| &nbsp; _**快速列表子菜单**_                  |                           |
| &nbsp; &nbsp; 上级文件夹                     | Cmd + 1                   |
| &nbsp; &nbsp; 历史记录                       | Cmd + 2                   |
| &nbsp; &nbsp; 收藏夹                         | Cmd + 3                   |
| &nbsp; &nbsp; 宗卷                           | Cmd + 4                   |
| &nbsp; &nbsp; 连接                           | Cmd + 5                   |
| &nbsp; &nbsp; 标签                           | Cmd + 6                   |
| &nbsp; 前往文件夹...                         | Shift + Cmd + G           |
| &nbsp; _**连接到子菜单**_                    |                           |
| &nbsp; &nbsp; FTP 服务器...                  |                           |
| &nbsp; &nbsp; SFTP 服务器...                 |                           |
| &nbsp; &nbsp; WebDAV 服务器...               |                           |
| &nbsp; &nbsp; 网络共享...                    |                           |
| &nbsp; &nbsp; 管理连接...                    | Cmd + K                   |
| _**命令（Command）菜单**_                    |                           |
| &nbsp; 简要系统概览                          | Cmd + L                   |
| &nbsp; 详细宗卷信息                          |                           |
| &nbsp; 文件属性                              | Ctrl + A                  |
| &nbsp; 打开扩展属性                          | Opt + Cmd + X             |
| &nbsp; 拷贝项目名称                          | Shift + Cmd + C           |
| &nbsp; 拷贝项目路径                          | Opt + Cmd + C             |
| &nbsp; 拷贝项目所在目录                      | Shift + Opt + Cmd + C     |
| &nbsp; 按通配符选中...                       | Cmd + =                   |
| &nbsp; 按扩展名选中                          | Opt + Cmd + =             |
| &nbsp; 按通配符取消选中...                   | Cmd + -                   |
| &nbsp; 按扩展名取消选中                      | Opt + Cmd + -             |
| &nbsp; 快速查看预览                          | Cmd + Y                   |
| &nbsp; 内置查看器                            | F3                        |
| &nbsp; 外部编辑器                            | F4                        |
| &nbsp; 推出宗卷                              | Cmd + E                   |
| &nbsp; 批量重命名...                         | Ctrl + M                  |
| &nbsp; 复制到...                             | F5                        |
| &nbsp; 另存复制到...                         | Shift + F5                |
| &nbsp; 重命名 / 移动到...                    | F6                        |
| &nbsp; 重命名 / 移动为...                    | Shift + F6                |
| &nbsp; 就地重命名                            | Ctrl + F6                 |
| &nbsp; 新建目录...                           | F7                        |
| &nbsp; 在对侧面板新建目录...                 | Shift + F7                |
| &nbsp; 移到废纸篓                            | Cmd + Backward Delete     |
| &nbsp; 放回原处                              |                           |
| &nbsp; 清倒废纸篓…                           |                           |
| &nbsp; 删除...                               | F8                        |
| &nbsp; 永久删除...                           | Shift + F8                |
| &nbsp; 压缩...                               | F9                        |
| &nbsp; 压缩到...                             | Shift + F9                |
| &nbsp; _**链接子菜单**_                      |                           |
| &nbsp; &nbsp; 创建硬链接                     |                           |
| &nbsp; &nbsp; 创建符号链接                   |                           |
| &nbsp; &nbsp; 编辑符号链接                   |                           |
| _**窗口（Window）菜单**_                     |                           |
| &nbsp; 最小化                                | Cmd + M                   |
| &nbsp; 进入全屏幕                            | Ctrl + Cmd + F            |
| &nbsp; 缩放                                  |                           |
| &nbsp; 显示上一个标签页                      | Shift + Ctrl + Tab        |
| &nbsp; 显示下一个标签页                      | Ctrl + Tab                |
| &nbsp; 前置全部窗口                          |                           |
| _**专用快捷键**_                             |                           |
| &nbsp; _**文件面板**_                        |                           |
| &nbsp; &nbsp; 光标上移                       | Up                        |
| &nbsp; &nbsp; 光标下移                       | Down                      |
| &nbsp; &nbsp; 光标左移                       | Left                      |
| &nbsp; &nbsp; 光标右移                       | Right                     |
| &nbsp; &nbsp; 光标移至首项                   | Home                      |
| &nbsp; &nbsp; 滚动至首项                     | Opt + Home                |
| &nbsp; &nbsp; 光标移至末项                   | End                       |
| &nbsp; &nbsp; 滚动至末项                     | Opt + End                 |
| &nbsp; &nbsp; 光标下翻页                     | Page Down                 |
| &nbsp; &nbsp; 滚动下翻页                     | Opt + Page Down           |
| &nbsp; &nbsp; 光标上翻页                     | Page Up                   |
| &nbsp; &nbsp; 滚动上翻页                     | Opt + Page Up             |
| &nbsp; &nbsp; 切换当前项选中状态             |                           |
| &nbsp; &nbsp; 切换选中并下移                 | Enter（Fn + Return）      |
| &nbsp; &nbsp; 切换激活面板                   | Tab                       |
| &nbsp; &nbsp; 上一个标签页                   | Shift + Cmd + [           |
| &nbsp; &nbsp; 下一个标签页                   | Shift + Cmd + ]           |
| &nbsp; &nbsp; 返回上级文件夹                 | Backward Delete           |
| &nbsp; &nbsp; 进入文件夹                     |                           |
| &nbsp; &nbsp; 前往个人主目录                 | Shift + ~                 |
| &nbsp; &nbsp; 前往根目录                     | /                         |
| &nbsp; &nbsp; 显示快速查看预览               | Space                     |
| &nbsp; &nbsp; 切换到第 1..10 个标签页        |                           |
| &nbsp; &nbsp; 聚焦左侧面板                   | Shift + Cmd + Left        |
| &nbsp; &nbsp; 聚焦右侧面板                   | Shift + Cmd + Right       |
| &nbsp; &nbsp; 显示上下文菜单                 | Ctrl + Return             |
| &nbsp; _**内置查看器**_                      |                           |
| &nbsp; &nbsp; 切换到文本模式                 | Cmd + 1                   |
| &nbsp; &nbsp; 切换到十六进制模式             | Cmd + 2                   |
| &nbsp; &nbsp; 切换到预览模式                 | Cmd + 3                   |
| &nbsp; &nbsp; 跳转到指定偏移 / 行            | Cmd + L                   |
| &nbsp; &nbsp; 刷新                           | Cmd + R                   |

# 常见问题（FAQ）

**问**：我有关于 Nimble Commander-Fork 的改进建议！  
**答**：欢迎在[项目仓库](https://github.com/cfanmaoli/nimble-commander)发起讨论或提交 Pull Request。提交代码前请先阅读 [CONTRIBUTING.md](https://github.com/cfanmaoli/nimble-commander/blob/main/CONTRIBUTING.md)。

---

**问**：能帮我实现某个特定功能需求吗？  
**答**：维护者精力有限，无法立即响应所有功能需求。欢迎社区提交质量良好、附带测试的 PR，详情参见 [CONTRIBUTING.md](https://github.com/cfanmaoli/nimble-commander/blob/main/CONTRIBUTING.md)。

---

**问**：应用出现崩溃或异常行为，如何反馈？  
**答**：请在 GitHub Issues 中附上你的 macOS 版本、应用构建号、清晰稳定的复现步骤以及崩溃日志或调试日志，这样能大大加快排查和修复速度。

---

**问**：快速查看预览缺少某种文件支持，能否添加？  
**答**：预览功能由 macOS 系统级 [Quick Look 框架](https://en.wikipedia.org/wiki/Quick_Look)负责，不同文件类型的渲染取决于系统已安装的 Quick Look 扩展，应用本身对此控制有限。

---

**问**：Nimble Commander-Fork 支持访问 iCloud 云盘吗？  
**答**：目前没有专门的 CloudKit 集成，但你可以直接跳转到 `~/Library/Mobile Documents/com~apple~CloudDocs` 目录并通过常规文件面板进行操作。

---

**问**：2.0 版本支持 Intel Mac 或 macOS 12 Monterey 吗？  
**答**：不支持。自 2.0 版本起，Nimble Commander-Fork 仅支持 Apple Silicon（`arm64`）芯片及 macOS 13 Ventura 及以上系统。如需 Intel（`x64`）或 macOS 12 支持，请从 [GitHub Releases](https://github.com/cfanmaoli/nimble-commander/releases) 下载 1.9.3c 版本。

---

**问**：如何下载历史版本？  
**答**：所有历史正式版均可在 [GitHub Releases](https://github.com/cfanmaoli/nimble-commander/releases) 直接下载，也可以检出对应 Git 标签自行从源码构建（参见 [Building.md](Building.md)）。

---

**问**：未来会支持直接修改已有压缩包内容吗？  
**答**：目前暂无相关开发计划，欢迎有兴趣的贡献者提交实现。

---

**问**：如何让应用在退出重开后恢复上次的窗口状态？  
**答**：前往「系统设置 → 桌面与程序坞」，关闭「退出应用程序时关闭窗口」选项。

---

**问**：如何查看以点开头的隐藏文件和文件夹（如 `.git`、`.folder`）？  
**答**：选择菜单 `显示 > 显示隐藏文件` 或按快捷键 `Shift + Cmd + .`。

---

**问**：如何把非标准扩展名的文件（如 `.xlsx`、`.pak`）当作压缩包打开？  
**答**：选择菜单 `前往 > 进入文件夹` 或按快捷键 `Cmd + Down`。

---

**问**：对话框里的按钮和选项有快捷键吗？  
**答**：有，许多对话框控件都支持 `Ctrl`（`^`）组合快捷键。将鼠标悬停在控件上可看到对应的快捷键提示。

---

**问**：Nimble Commander-Fork 将配置和状态保存在哪里？  
**答**：位于以下路径：

- 主配置文件（由应用管理）：  
  `~/Library/Application Support/Nimble Commander-Fork/Config`
- 运行时状态文件（由应用管理）：  
  `~/Library/Application Support/Nimble Commander-Fork/State`
- 窗口状态（由 macOS 管理）：  
  `~/Library/Saved Application State/info.filesmanager.Files.savedState`
- 应用偏好默认设置（由 macOS 管理）：  
  `~/Library/Preferences/info.filesmanager.Files.plist`
- 管理员模式特权守护进程（由 macOS 通过 `SMAppService` 管理）：  
  内嵌在应用包中（`Contents/Library/LaunchDaemons/info.filesmanager.Files.PrivilegedIOHelperV3.plist` 与 `Contents/Library/LaunchServices/info.filesmanager.Files.PrivilegedIOHelperV3`），可在「系统设置 → 通用 → 登录项与扩展」中管理

---

**问**：为什么重启应用或切换系统外观后，我选的主题会被重置？  
**答**：通常是因为开启了“自动主题切换”，会在 macOS 切换浅色/深色外观或重启时自动套用预设主题。你可以在 `偏好设置 > 主题 > (...) > 配置自动切换...` 中关闭该功能，或分别指定浅色与深色模式对应的主题。

---

**问**：在哪里查看运行日志？  
**答**：按住 `Opt` 键并点击菜单 `帮助 > 调试 > 显示日志...`（`Help > Debug > Show Logs...`）。点击日志窗口中的齿轮图标可按子系统或全局设置日志级别（默认关闭）。
