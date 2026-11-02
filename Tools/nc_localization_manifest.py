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
import re
import sys

# which resource bundle a catalog ends up in, keyed by the sub-project folder
BUNDLE_BY_SUBPROJECT = {
    "NimbleCommander": "",
    "Operations": "OperationsResources.bundle",
    "Panel": "PanelResources.bundle",
    "Viewer": "ViewerResources.bundle",
    "CUI": "CUIResources.bundle",
    "RoutedIO": "RoutedIOResources.bundle",
    "Utility": "UtilityResources.bundle",
}

# read by the system, not by the app - can't be overridden anyway
SKIPPED_TABLES = {"InfoPlist"}


# keys of interface-file strings look like "ftk-l8-B5i.title" - the object id plus the property
XIB_KEY = re.compile(r"^(?P<object>[A-Za-z0-9]{3}-[A-Za-z0-9]{2}-[A-Za-z0-9]{3})\\.(?P<prop>[A-Za-z]+)$")


def xib_literal(xib_path, object_id, prop):
    """The English text of an interface element, read straight out of the .xib.

    Xcode only writes an "en" entry into a catalog when the value differs from the key, and a
    key such as "ftk-l8-B5i.title" says nothing about the text - without this, English mode has
    no way to show the original for those entries and falls back to the system language.
    """
    try:
        with open(xib_path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return None
    element = re.search(r'<[^>]*\\bid="%s"[^>]*>' % re.escape(object_id), text)
    if element is None:
        return None
    tag = element.group(0)
    attribute = re.search(r'\\b%s="([^"]*)"' % re.escape(prop), tag)
    if attribute is not None:
        return attribute.group(1)
    child = re.search(r'<string key="%s">(.*?)</string>' % re.escape(prop), text, re.S)
    if child is not None:
        return child.group(1)
    return None


def interface_file_for(catalog_path):
    """mul.lproj/Name.xcstrings -> Base.lproj/Name.xib (and the other way round)."""
    directory, name = os.path.split(catalog_path)
    stem, _extension = os.path.splitext(name)
    for lproj in ("Base.lproj", "Mul.lproj"):
        candidate = os.path.join(os.path.dirname(directory), lproj, stem + ".xib")
        if os.path.exists(candidate):
            return candidate
    return None


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
            if value is None:
                # no "en" entry: for a code string the key IS the English text, for an
                # interface string the original has to come from the .xib
                match = XIB_KEY.match(key)
                if match is None:
                    value = key
                else:
                    xib = interface_file_for(path)
                    value = xib_literal(xib, match.group("object"), match.group("prop")) if xib else None
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
