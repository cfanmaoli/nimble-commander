#!/usr/bin/env python3
"""Builds the localization manifest that ships inside the app.

The compiled bundle only contains the translations of each language - the English source
strings of the interface files live inside the compiled .nib files and can't be read back at
runtime. The manifest carries them (plus the translator comments) so that the "export current
language" feature can produce a file a human can actually translate.

    Tools/nc_localization_manifest.py <output.json> [repo-root]
"""
import datetime
import json
import os
import sys

# which resource bundle a catalog ends up in, keyed by the sub-project folder
BUNDLE_BY_SUBPROJECT = {
    "NimbleCommander": "",
    "Operations": "OperationsResources.bundle",
    "Panel": "PanelResources.bundle",
    "Viewer": "ViewerResources.bundle",
    "CUI": "CUIResources.bundle",
    "RoutedIO": "RoutedIOResources.bundle",
}

# read by the system, not by the app - can't be overridden anyway
SKIPPED_TABLES = {"InfoPlist"}


def unit_value(localization):
    if not isinstance(localization, dict):
        return None
    unit = localization.get("stringUnit")
    if isinstance(unit, dict) and unit.get("value") is not None:
        return unit["value"]
    variations = localization.get("variations")
    if isinstance(variations, dict):
        for kind in ("plural", "device"):
            variants = variations.get(kind)
            if not isinstance(variants, dict):
                continue
            for category in ("other", "many", "few", "two", "one", "zero"):
                if category in variants:
                    value = unit_value(variants[category])
                    if value is not None:
                        return value
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    destination = sys.argv[1]
    root = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    source = os.path.join(root, "Source")

    entries = []
    files = []
    for dirpath, _dirnames, filenames in os.walk(source):
        for name in filenames:
            if name.endswith(".xcstrings"):
                files.append(os.path.join(dirpath, name))
    files.sort()

    skipped_tables = set()
    for path in files:
        relative = os.path.relpath(path, root)
        parts = relative.split(os.sep)
        if len(parts) < 3 or parts[0] != "Source":
            continue
        subproject = parts[1]
        if subproject not in BUNDLE_BY_SUBPROJECT:
            print("warning: no bundle mapping for %s - skipped" % relative, file=sys.stderr)
            continue
        bundle = BUNDLE_BY_SUBPROJECT[subproject]
        table = os.path.splitext(os.path.basename(path))[0]
        if table in SKIPPED_TABLES:
            skipped_tables.add(table)
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                catalog = json.load(handle)
        except Exception as error:  # noqa: BLE001 - report and carry on
            print("warning: can't read %s (%s)" % (relative, error), file=sys.stderr)
            continue
        for key, entry in (catalog.get("strings") or {}).items():
            localization = (entry.get("localizations") or {}).get(catalog.get("sourceLanguage", "en"))
            value = unit_value(localization)
            item = {
                "bundle": bundle,
                "table": table,
                "key": key,
                "source": value if value is not None else "",
            }
            comment = entry.get("comment")
            if comment:
                item["comment"] = comment
            entries.append(item)

    entries.sort(key=lambda item: (item["bundle"], item["table"], item["key"]))
    manifest = {
        "sourceLanguage": "en",
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "entryCount": len(entries),
        "entries": entries,
    }
    directory = os.path.dirname(os.path.abspath(destination))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(destination, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    print("localization manifest: %d entries from %d catalogs -> %s" % (len(entries), len(files), destination))
    return 0


if __name__ == "__main__":
    sys.exit(main())
