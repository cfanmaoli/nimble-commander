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
上游在 1.9.0 发布后停止维护，本分支从该版本继续。

## 默认就是中文

本分支继承了 `main` 的中文本地化，开箱即用：

- 菜单、偏好设置、各文件操作对话框、错误提示、权限申请等界面文案都已翻译，约 1,460 条字符串。
- 在中文系统上安装后直接显示中文界面，**不需要**另外下载语言包或重新编译。
- 想换语言或参与翻译：**偏好设置 → 语言**，可切换内置语言、导入/导出 JSON 语言包，不需要 Xcode。
- 尚未翻译的还有 [WHATS_NEW.md](WHATS_NEW.md)、[Docs/Help.md](Docs/Help.md) 用户手册和部分开发文档。

## 本分支在 `main` 之上多出来的东西

`main` 分支的所有内容，再加上：

- **用 UnRAR 读 RAR** —— 归档的列表与解压改用官方 UnRAR 7.3.2 库，而不是 libarchive；对固实（solid）归档
  的读取结果正确，大归档的列表也快得多。
- **带密码的 RAR** —— 加密的文件头和内容都能正确弹出密码提示。
- **多卷 RAR** —— `.part1.rar` / `.r00` 系列会自动跟进。

其余内容（仅 Apple Silicon、语言包、额外主题、废纸篓支持、各种修复）与 `main` 完全一致。

## 编译

见 [Docs/Building.md](Docs/Building.md)。随附的第三方库已经为 arm64 预编译好，需要自己重建时运行
`3rd_Party/bootstrap.sh`。请记住：你编译出来的程序包含 UnRAR，因此不得对外发布。

## 许可证

项目自身的源代码以 GNU 通用公共许可证第 3 版发布，版权所有 (C) 2013-2026 Michael Kazakov 及各位贡献者。

随附的 UnRAR 源代码版权归 `(c) Alexander Roshal`，按它自己的许可证分发：允许用于任何软件，但要求把许可证
文本与程序一起保留。把它和 GPLv3 代码组合在一起，正是本分支无法分发的原因，也是这里不提供任何编译产物的
原因。
