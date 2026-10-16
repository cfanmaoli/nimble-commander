# 语言包（导入 / 导出语言 JSON）

这是 fork 里加的一个二次开发功能：**在「偏好设置 → 语言」里把当前界面语言导出成一个 JSON，
翻译好之后再导入回来，重启应用即可显示译文**。不需要改代码、不需要重新编译、也不需要重新签名。

## 用法

1. 打开 **偏好设置（⌘,）→ 语言**。
   - 顶部的 **「界面语言」** 下拉框可以直接切换：**跟随系统 / English / Русский / 简体中文**，
     以及所有已导入的语言包。选完会提示重启，点「立即重启」即可。
     - 内置语言和语言包用的是**同一套覆盖层机制**：启动时读目标语言的 `.lproj`，
       缺口用 manifest 里的英文原文补。选择状态存在 `LanguagePacks/active.txt`
       （`builtin:ru` / `pack:ja` / 空 = 跟随系统）。
     - **故意不写 `AppleLanguages`**：见下面「已知限制」。所以侧边栏那些由系统提供的名称
       （文稿 / 下载 / 桌面）和日期、数字格式仍然跟随系统语言，只有 app 自己画的文字会换。
2. 点 **导出当前语言…**，保存出一个 JSON（默认文件名是当前语言代码，例如 `zh-Hans.json`）。
   - 每个条目长这样：
     ```json
     { "bundle": "", "table": "MainMenu", "key": "129.title",
       "source": "Preferences…", "translation": "偏好设置…" }
     ```
   - `source` 是英文原文（来自 `LocalizationManifest.json`），`translation` 是当前语言的译文。
   - 界面文件（XIB）的条目标识是 `ObjectID.属性`（如 `129.title`），看 `source` 就知道它是什么。
3. 把 `language` 改成目标语言代码（`ja`、`ko`、`zh-Hant`…），`languageName` 可留可改，
   然后逐条替换 `translation`。没有翻译的条目留空就会回退到原文。
4. 回到 **偏好设置 → 语言**，点 **导入语言文件…**，选中改好的 JSON。
   - 导入时会做校验：**译文缺少或多出格式占位符（`%@`/`%d`…）的条目会被跳过**，
     否则运行时 `stringWithFormat:` 会打印乱码甚至崩溃。占位符只是换了位置参数
     （`%@ … %@` → `%1$@ … %2$@`）是允许的。
5. 点 **立即重启**（或稍后自己重启）。重启后整个界面就是新语言了。

> **"为什么导入了还是中文？"** 导出的文件里每条 `translation` 都预先填好了当前语言的文本，
> 所以**没动过的条目导入后当然还是原来的语言**（不是 bug）。导入完成时弹窗会告诉你
> 「其中 N 条与当前语言的文本相同，看起来还没有翻译」，「偏好设置 → 语言」里也会显示
> 「已翻译 N 条」。要整个界面都变成新语言，就得把 1432 条都译完。
>
> 回退规则：**语言包里没有的 key、或者译文为空的条目 → 回退到 app 的内置语言**（这里是中文）。
6. 不想要了就点 **移除**，再重启一次即可回到内置语言。

## 它是怎么工作的

整个 app 的本地化查询只有一个收口点：

```
-[NSBundle localizedStringForKey:value:table:]
```

`NSLocalizedString`、`NSLocalizedStringFromTable`、以及 **AppKit 装载 XIB/nib 时的字符串替换**
全都走这个方法（table 名就是 nib 名，key 是 `ObjectID.属性`）。所以
`Source/NimbleCommander/NimbleCommander/Core/LanguagePack.mm` 在 `+load` 里把它 swizzle 掉，
先查语言包、查不到再走原实现。`+load` 早于 app 里所有 C++ 静态全局的初始化，
所以连 `static const auto g_CloseWindowTitle = NSLocalizedString(@"Close Window")` 这种写法也能覆盖。

语言包存放在：

```
~/Library/Application Support/Nimble Commander/LanguagePacks/
    active.txt      # 当前启用的语言代码，空/不存在 = 使用内置语言
    ja.json         # 导入时被规范化后的语言包
```

**不改动 .app 里任何文件**，所以签名始终有效；切换语言需要重启，因为已经加载的 nib
和静态全局不会重新求值。

覆盖范围：主 bundle + 5 个资源 bundle（Operations/Panel/Viewer/CUI/RoutedIO）共约 **1432 条**、
53 张表。**不覆盖** `InfoPlist.strings`（权限弹窗由系统直接读取 lproj，绕不过去）。

## LocalizationManifest.json

编译进 app 的英文原文清单，由 `Tools/nc_localization_manifest.py` 从 54 个 `.xcstrings` 生成：

```bash
python3 Tools/nc_localization_manifest.py \
    "/path/to/Nimble Commander.app/Contents/Resources/LocalizationManifest.json" .
```

没有它导出也能用，只是 `source` 会为空——而 XIB 条目的 key 是 `129.title` 这种，
没有英文原文基本没法翻。所以打包时务必生成（`nc-l10n-work/sign-install2.sh` 已经这么做了）。

## 改动清单

| 文件 | 说明 |
|---|---|
| `Source/NimbleCommander/NimbleCommander/Core/LanguagePack.{h,mm}` | 新增：swizzle、语言包读写、导出/导入 |
| `Source/NimbleCommander/NimbleCommander/Preferences/PreferencesWindowLanguageTab.{h,mm}` | 新增：偏好设置里的「语言」标签页（纯代码构建视图） |
| `Source/NimbleCommander/NimbleCommander/Preferences/Preferences.mm` | 注册新标签页 |
| `Source/NimbleCommander/NimbleCommander/Preferences/Preferences.xcstrings` | 新增 33 条界面文案（en + zh-Hans） |
| `Tools/nc_localization_manifest.py` | 新增：生成英文原文清单 |
| `NimbleCommander.xcodeproj/project.pbxproj` | 把新文件加进 NimbleCommanderCommon target |

## 已知限制

- 切换语言要重启。
- 未翻译的条目回退到**内置语言**（中文）而不是英文原文——因为"只想改几个词"的场景下
  回退英文会把整个界面变成英文。想改成回退英文的话，`LanguagePack.mm` 里已经有
  `NativeStringsIndex()` 能取到内置文本，再叠一个由 manifest 生成的英文覆盖层即可。
- `InfoPlist.strings`（6 条权限提示）覆盖不了。
- **不要用 `AppleLanguages` 切换语言**（我们试过，已移除）：
  只要 app 带着自己的 `AppleLanguages` 覆盖值运行（`defaults write info.filesmanager.Files
  AppleLanguages -array ru`，或系统设置里的「应用程序语言」），**弹出任何 NSAlert 时都会崩溃** ——
  `AppKit +[NSApplication _crashOnException:]` ← `-[NSAlert runModal]` 的 display cycle 里
  `NSInternalInconsistencyException`，断言在 `CUINamedVectorGlyph.m:2599`，即 CoreUI 在光栅化
  SF Symbol 时挂掉（`PanelViewHeader.mm` 里的 `xmark.circle.fill` / `magnifyingglass`）。
  这是上游 app 自身的隐患（任何俄语用户只要通过系统设置给 app 指定语言就会遇到），
  本功能不趟这个坑。
- 导出的 JSON 是**当前语言**的全量快照；app 升级后旧语言包里失效的 key 会被忽略（自动回退原文），
  新增的 key 需要重新导出补齐。
- 如果某条目在 app 里是用 `stringWithFormat:` 之外的方式使用（例如做字符串比较），
  翻译它可能影响逻辑；`SpdLogWindow.mm` 里的 `" [warning] "` 等就是故意不翻的例子。
