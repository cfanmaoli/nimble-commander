# Nimble Commander-Fork —— `evil` 分支

[English](README.md) | **简体中文**

> ## ⚠️ 这是 evil 分支
>
> 和 [`main` 分支](https://github.com/cfanmaoli/nimble-commander/tree/main)不同，本分支打包了专有的
> **UnRAR** 库，以获得最好的 RAR 支持。这导致编译产物无法在 GPLv3 许可证下分发。
>
> - **本分支永远不会提供编译好的程序、DMG、每日构建或发行版。**
> - **请自己编译**（见 [Docs/Building.md](Docs/Building.md)）。
> - **不要分发**任何由本分支编译出来的东西。
>
> 本分支仅供个人使用。干净、符合 GPLv3 的版本 —— 用 libarchive 读取 RAR —— 在
> [`main` 分支](https://github.com/cfanmaoli/nimble-commander/tree/main)。

---

Nimble Commander-Fork 是 [Nimble Commander](https://github.com/mikekazakov/nimble-commander) 的社区维护分支。
Nimble Commander 是一款面向 macOS 的免费双栏文件管理器，主打速度、纯键盘操作和可定制性。

上游在 1.9.0 发布后停止维护，本分支从该版本继续。界面、文档和文件格式沿用上游，只改了应用名称，
以免和原项目混淆。

![](Docs/nc.png)

## 本分支的改动

- **默认就是中文** —— 内置完整的简体中文本地化（菜单、偏好设置、文件操作对话框、错误提示、权限申请等，
  约 1,460 条字符串）。中文系统安装后直接显示中文，**不需要**另外下载语言包。
- **仅支持 Apple Silicon** —— 应用本身和所有随附的静态库都只构建 arm64，不再支持 Intel。
- **语言包** —— *偏好设置 → 语言* 可以把当前语言的界面字符串导出成 JSON，把翻译导回来，并在内置语言和
  导入的语言包之间切换，不需要 Xcode、重新编译或重新签名。详见
  [Tools/language-packs.md](Tools/language-packs.md)。
- **更多内置主题** —— 在原有的 Light、Dark、Classic 之外，新增 Solarized（亮/暗）、Nord、Dracula、
  Gruvbox（亮/暗）、One Dark、Tokyo Night、Catppuccin（Mocha/Latte）、GitHub Dark 和 Monokai。
- **平铺视图** —— `显示 > 平铺`（快捷键 `Option + Command + B`）把当前目录及其所有子目录里的文件和文件夹
  一次性列在同一个面板里。本分支里它使用下面提到的列式枚举，速度快很多。
- **支持废纸篓** —— 可以浏览 `~/.Trash` 和各磁盘的废纸篓（`/Volumes/*/.Trashes/<uid>`），一次清空全部，
  也可以把条目放回原来的位置。
- **用 UnRAR 读 RAR** —— 这是本分支在 `main` 之上多出来的部分：归档的列表与解压改用官方 UnRAR 7.3.2 库，
  而不是 libarchive；对固实（solid）归档的读取结果正确，大归档的列表也快得多，加密的文件头和内容都能
  正确弹出密码提示，`.part1.rar` / `.r00` 系列会自动跟进。
- **零散修复** —— 归档扫描可取消、快速过滤支持拼音首字母、快速过滤新增正则表达式模式、鼠标侧键前进/后退，
  以及用本地证书签名后依然可用的特权助手。

## 海量目录下的性能

本分支还包含一组针对几十万条目目录的优化（以 100 万条目的目录为基准）。测量方法与推理见
[Docs/Performance.md](Docs/Performance.md)，简表如下：

| | 之前 | 现在 |
|---|---|---|
| 100 万条目目录的首屏 | ~2.2 s | **~34 ms**（先显示预览，其余在后台继续读）|
| 100 万条目目录里的单次变化 | 2.4 s（默认视图设置下整目录重载）| **~40 ms**（路径级 FSEvents + 增量补丁）|
| 读取目录本身 | ~5.7 s CPU | ~2.35 s，其中 2.17 s 是内核枚举 |
| 常驻内存（100 万条目）| ~650 MB | 默认 ~283 MB，lazy 模式 ~252 MB |

平铺视图与“查找文件”面板也各有快路径（列式树枚举、并行的文件名/内容搜索），测量与实现在
[Docs/VFS-Peel-Evaluation.md](Docs/VFS-Peel-Evaluation.md)。

有两个可选设置可以在超大目录上用信息换内存，位于
`~/Library/Application Support/Nimble Commander-Fork/Config/Config.json`，默认关闭：

- `filePanel.general.lazyDates` —— 枚举时跳过五个时间列（每百万条目省 20 MB），滚动时再补日期列
  （面板会对可见行做 stat）。
- `filePanel.general.lazySizes` —— 对大小列做同样的事（再省 8 MB）。

打开其中任何一个后，按受影响的列排序会先用完整属性重载目录，未取到的行显示 `--`。

## 从源码编译

见 [Docs/Building.md](Docs/Building.md)。随附的第三方库已经为 arm64 预编译好，需要自己重建时运行
`3rd_Party/bootstrap.sh`。注意：你编译出来的是包含 UnRAR 的程序，不能对外发布。

## 文档

用户手册见 [Docs/Help.md](Docs/Help.md)（英文）。

## 更新日志

每个版本的改动见 [WHATS_NEW.md](WHATS_NEW.md)。

## 参与贡献

欢迎提交代码、报告问题和贡献翻译 —— 见 [CONTRIBUTING.md](CONTRIBUTING.md)。
本项目由 DeepSeek 在人工全程监督与审查下编写。

## 许可证

项目自身的源代码以 GNU 通用公共许可证第 3 版发布。
版权所有 (C) 2013-2026 Michael Kazakov，以及 Nimble Commander-Fork 的各位贡献者对其改动的部分。

随附的 UnRAR 源代码版权归 `(c) Alexander Roshal`，按其自有许可证分发：允许用于任何软件，但要求
随包保留许可证文本。它与 GPLv3 代码组合后使得本分支无法再分发——这也是本分支不提供任何构建产物的原因。
