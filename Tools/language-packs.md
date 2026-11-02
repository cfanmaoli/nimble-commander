# Language packs

**Fork-only feature.** It was offered upstream in
[#746](https://github.com/mikekazakov/nimble-commander/issues/746) and declined — the author prefers
the app to ship a fixed set of translations and let macOS choose the language. It is therefore *not*
a candidate for a pull request; the whole thing lives on the `language-packs` branch of this fork.

---

## What it does

A **Preferences → Language** tab that

* **exports** every string of the current interface language into a JSON file,
* **imports** a translated copy of that file back,
* switches between the languages the app ships and any imported pack,
* removes packs again.

## Why

Nimble Commander ships English, Russian and Simplified Chinese. Anyone whose language is not on
that list has no practical way to get one: a real translation means touching 55 String Catalogs
across seven Xcode projects, and getting it merged means finding someone to maintain it.

The exported file is plain JSON with the English source sitting next to every entry — which is
exactly the shape an AI can translate in one pass. Export, ask for a translation into your own
language, import, restart. No Xcode, no signing, no maintainer in the loop. That is the entire
point of the feature: making "my language is not supported" something a user can fix without
waiting for someone else.

## Quick start

1. **Preferences → Language → Export Current Language…** — writes one entry per string:

   ```json
   { "bundle": "", "table": "MainMenu", "key": "129.title",
     "source": "Preferences…", "translation": "偏好设置…" }
   ```

   `source` is the English original, `translation` the current language. Strings that live in
   interface files are keyed by `ObjectID.property` (`129.title`); `source` is what tells a
   translator what such an entry actually is.

2. Set `language` to the target code (`ja`, `ko`, `zh-Hant`…) and replace the `translation`
   values — any text editor, or hand the whole file to an AI and ask for a translation.

3. **Import Language File…**, accept the restart prompt, done.

> **"I imported it but everything is still in the old language"** — an exported file has the
> *current* language pre-filled in every `translation`, so the entries you did not touch stay in
> that language. The import report and the Language tab both say how many entries are still
> identical to the old language, so a half-finished pack is easy to spot.

Import validates each entry and refuses the ones whose format specifiers would break at runtime
(a dropped `%@` prints garbage). Positional arguments (`%1$@`), flags and precision changes are
fine, and a plural source such as `Compressing %#@items@` may be spelled out with a plain `%d`.

## Switching languages

The **interface language** popup lists *follow the system*, every language the app ships and every
imported pack. Changing it does not take effect until the app restarts — the **Restart to Apply**
button next to the popup does that, after asking once.

The selection is stored in `~/Library/Application Support/Nimble Commander/LanguagePacks/active.txt`:

    builtin:ru      one of the bundled languages
    pack:ja         an imported pack
    (empty)         follow the system

Packs themselves live in the same folder as `<identifier>.json`.

## Removing packs

The **language pack** popup lists every installed pack, and **Remove** deletes the selected one —
the active pack is preselected, but any pack can be removed without activating it first. Removing
the pack that is currently in use asks for a restart; removing another one does not.

## How it works

Every localized lookup in the app funnels through

    -[NSBundle localizedStringForKey:value:table:]

`NSLocalizedString`, the four resource bundles' helpers and AppKit's own nib string substitution
all end up there — a test harness confirmed that loading a nib calls it with the nib's name as the
table and `ObjectID.property` as the key, and that the returned value lands in the loaded view.

`LanguagePack.mm` therefore swizzles that single method from `+load` (which runs before the app's
C++ static initializers, so file-scope globals such as `g_CloseWindowTitle` are covered too) and
consults the active pack first. Nothing inside the `.app` is modified, so the code signature stays
valid and the feature works on a signed, released copy.

Built-in languages go through the same overlay: the chosen `<language>.lproj` is read at startup
and the gaps are filled from `LocalizationManifest.json`, so a partially localized language falls
back to English rather than to whatever the system language happens to be. The manifest itself is
generated from the 55 `.xcstrings` files by a run-script build phase
(`Tools/nc_localization_manifest.py`), because the English originals of interface strings only
exist inside the compiled nibs.

We deliberately do **not** write `AppleLanguages`. Running the app under a per-app language
override makes AppKit assert inside CoreUI while rasterising an SF Symbol
(`CUINamedVectorGlyph.m:2599`, reproducible with `defaults write info.filesmanager.Files
AppleLanguages -array ru` and any `NSAlert`) — a problem of its own that this feature should not
step into.

## Known limits

* switching language requires a restart;
* `InfoPlist.strings` (the permission prompts) cannot be overridden — the system reads those files
  directly;
* strings that macOS itself provides (the Apple menu, *Quit and Keep Windows*, the sidebar names,
  date and number formats) keep following the system language, for the reason above;
* a pack is a snapshot: keys that disappear after an app update are ignored, new keys need a fresh
  export;
* strings the app compares rather than displays must not be translated (the spdlog tags in
  `SpdLogWindow.mm` are the example).

## Files

| file | what |
|---|---|
| `Source/NimbleCommander/NimbleCommander/Core/LanguagePack.{h,mm}` | overlay, pack storage, export/import, validation |
| `Source/NimbleCommander/NimbleCommander/Preferences/PreferencesWindowLanguageTab.{h,mm}` | the Preferences tab (views built in code) |
| `Source/NimbleCommander/NimbleCommander/Preferences/Preferences.mm` | registers the tab |
| `Tools/nc_localization_manifest.py` | generates the English source manifest at build time |

## Building

The branch is rebased on upstream `main`, so the normal build works as-is:

    xcodebuild -project Source/NimbleCommander/NimbleCommander.xcodeproj \
               -scheme NimbleCommander-Unsigned -configuration Release build

No packaging script is needed — the manifest is produced by a build phase on the three app targets.

A full Japanese translation (~1160 unique strings, 1439 entries) was produced with this workflow
and used to check that the menu bar, column headers, status bar, dialogs and every Preferences tab
really come out in the target language.
