# Language packs: translating the UI without a rebuild

This fork adds a **Preferences → Language** tab that exports every string of the current UI
language into a JSON file, and imports a translated copy of it back:

1. **Export Current Language…** writes a pack with one entry per string:

   ```json
   { "bundle": "", "table": "MainMenu", "key": "129.title",
     "source": "Preferences…", "translation": "偏好设置…" }
   ```

   `source` is the English original (it comes from `LocalizationManifest.json`, see below),
   `translation` is the current language's text. Strings that live in interface files are keyed
   by `ObjectID.property` (e.g. `129.title`) - `source` is what tells a translator what they are.

2. Change `language` to the target code (`ja`, `ko`, `zh-Hant`…), replace the `translation`
   values, then **Import Language File…** and restart.

Import validates every entry and refuses the ones whose format specifiers would break at
runtime (a dropped `%@` prints garbage). Positional arguments (`%1$@`), flag and precision
changes are fine, and plural sources such as `Compressing %#@items@` may be spelled out with
a plain `%d`.

> **"I imported it but everything is still in the old language"** - an exported file has the
> *current* language pre-filled in every `translation`, so the entries you did not touch stay
> in that language (that is not a bug). The import dialog reports how many entries are still
> identical to the current language, and the Language tab shows "N entries - M translated".

## Built-in languages

The same overlay mechanism switches between the languages the app ships. Reading
`<language>.lproj` at startup and filling the gaps from the manifest means a partially
localised language falls back to English instead of to whatever the system language is.

The selection lives in `~/Library/Application Support/<app>/LanguagePacks/active.txt`:

    builtin:ru      one of the bundled languages
    pack:ja         an imported pack
    (empty)         follow the system

We deliberately do **not** write `AppleLanguages`. Running the app under a per-app language
override makes AppKit assert inside CoreUI while rasterising an SF Symbol
(`CUINamedVectorGlyph.m:2599`, reproducible with `defaults write info.filesmanager.Files
AppleLanguages -array ru` and any `NSAlert`) - that is an upstream problem of its own and
this feature should not step into it. The trade-off is that names provided by the system
(the sidebar) and date/number formats keep following the system language.

## How it works

Every localized lookup in the app funnels through

    -[NSBundle localizedStringForKey:value:table:]

`NSLocalizedString`, the four resource bundles' helpers and AppKit's own nib string
substitution all end up there - a test harness confirmed that loading a nib calls it with the
nib's name as the table and the `ObjectID.property` as the key, and that the returned value
lands in the loaded view. `LanguagePack.mm` therefore swizzles that one method from `+load`
(which runs before the app's C++ static initializers, so file-scope globals such as
`g_CloseWindowTitle` are covered too) and consults the active pack first.

Nothing inside the `.app` is touched, so the code signature stays valid.

## LocalizationManifest.json

The English originals of interface strings are baked into the compiled nibs and cannot be read
back at runtime, so a build phase generates a manifest from the 54 `.xcstrings` files
(`Tools/nc_localization_manifest.py`, wired into the three app targets). Without it the export
still works but the `source` field is empty, which makes `129.title`-style entries unusable.

## Files

| file | what |
|---|---|
| `Source/NimbleCommander/NimbleCommander/Core/LanguagePack.{h,mm}` | swizzle, pack storage, export/import/validation |
| `Source/NimbleCommander/NimbleCommander/Preferences/PreferencesWindowLanguageTab.{h,mm}` | the Preferences tab (views built in code) |
| `Source/NimbleCommander/NimbleCommander/Preferences/Preferences.mm` | registers the tab |
| `Tools/nc_localization_manifest.py` | generates the English source manifest |

## Known limits

- switching language needs a restart;
- `InfoPlist.strings` (the six permission prompts) cannot be overridden - the system reads
  those files directly;
- a pack is a snapshot: keys that disappear after an app update are ignored, new keys need a
  fresh export;
- strings that the app compares rather than displays must not be translated (the spdlog tags in
  `SpdLogWindow.mm` are the example);
- system-provided names and date/number formats follow the system language, see above.
