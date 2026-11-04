# Nimble Commander-Fork

[English](README.md) | **简体中文**

Nimble Commander-Fork 是 [Nimble Commander](https://github.com/mikekazakov/nimble-commander) 的社区维护分支。
Nimble Commander 是一款面向 macOS 的免费双栏文件管理器，主打速度、纯键盘操作和可定制性。

上游在 1.9.0 发布后停止维护，本分支从该版本继续。界面、文档和文件格式沿用上游，只改了应用名称，
以免和原项目混淆。

![](Docs/nc.png)

## 默认就是中文

本分支内置简体中文本地化，开箱即用：

- 菜单、偏好设置、各文件操作对话框、错误提示、权限申请等界面文案都已翻译，约 1,460 条字符串。
- 在中文系统上安装后直接显示中文界面，**不需要**另外下载语言包或重新编译。
- 想换语言：**偏好设置 → 语言**，可在内置语言之间切换，也可以导入自己翻译的语言包。
- 想参与翻译：同在这个标签页里导出 JSON 翻译稿，翻译完再导回来即可，不需要 Xcode。

尚未翻译的还有 [WHATS_NEW.md](WHATS_NEW.md)、[Docs/Help.md](Docs/Help.md) 用户手册和部分开发文档，欢迎补充。

## 本分支的改动

- **仅支持 Apple Silicon** —— 应用本身和所有随附的静态库都只构建 arm64，不再支持 Intel。
- **语言包** —— *偏好设置 → 语言* 可以把当前语言的界面字符串导出成 JSON，把翻译导回来，并在内置语言和
  导入的语言包之间切换，不需要 Xcode、重新编译或重新签名。详见
  [Tools/language-packs.md](Tools/language-packs.md)。
- **更多内置主题** —— 在原有的 Light、Dark、Classic 之外，新增 Solarized（亮/暗）、Nord、Dracula、
  Gruvbox（亮/暗）、One Dark、Tokyo Night、Catppuccin（Mocha/Latte）、GitHub Dark 和 Monokai。
- **平铺视图** —— `显示 > 平铺`（快捷键 `Option + Command + B`）把当前目录及其所有子目录里的文件和文件夹
  一次性列在同一个面板里，处理层级很深的目录时不用来回进出。
- **支持废纸篓** —— 可以浏览 `~/.Trash` 和各磁盘的废纸篓（`/Volumes/*/.Trashes/<uid>`），一次清空全部，
  也可以把条目放回原来的位置。
- **RAR 支持且不涉及专有代码** —— RAR 归档通过 libarchive 读取，和上游用的是同一套后端；本分支不附带任何
  第三方 RAR 实现。
- **零散修复** —— 归档扫描可取消、快速过滤支持拼音首字母、快速过滤新增正则表达式模式、鼠标侧键前进/后退，
  以及用本地证书签名后依然可用的特权助手。

## 从源码编译

见 [Docs/Building.md](Docs/Building.md)。随附的第三方库已经为 arm64 预编译好，需要自己重建时运行
`3rd_Party/bootstrap.sh`。

## 文档

用户手册见 [Docs/Help.md](Docs/Help.md)（英文）。

## 更新日志

每个版本的改动见 [WHATS_NEW.md](WHATS_NEW.md)。

## 参与贡献

欢迎提交代码、报告问题和贡献翻译 —— 见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

Nimble Commander-Fork 以 GNU 通用公共许可证第 3 版发布。
版权所有 (C) 2013-2026 Michael Kazakov，以及 Nimble Commander-Fork 的各位贡献者对其改动的部分。
