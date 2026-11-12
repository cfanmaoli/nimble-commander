#!/usr/bin/env python3
# Copyright (C) 2026 The Nimble Commander-Fork Authors. Subject to GNU General Public License version 3.
"""Regenerate appcast.xml from the GitHub releases of the fork.

The appcast is the Sparkle update feed served from the root of the 'main' branch. It lists the
latest tagged release and the rolling 'nightly' pre-release, with the enclosures pointing at the
DMG assets of those releases on GitHub. Every enclosure is signed with the Sparkle EdDSA key and
the signature is embedded into the item.

Usage:
    Scripts/update_appcast.py                    # regenerate appcast.xml
    Scripts/update_appcast.py --dry-run          # print the feed to stdout only
    Scripts/update_appcast.py --tag v1.9.2       # use another stable tag
    Scripts/update_appcast.py --no-nightly       # skip the nightly pre-release

The private key is read from ~/.sparkle-fork/ed25519.key by default (override with --key-file or
the SPARKLE_ED_KEY_FILE environment variable). It must never be committed - the public counterpart
lives in NimbleCommander-NonMAS-Info.plist as SUPublicEDKey.
"""

import argparse
import base64
import email.utils
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

REPO = "cfanmaoli/nimble-commander"
API = f"https://api.github.com/repos/{REPO}"
DEFAULT_KEY_FILE = Path.home() / ".sparkle-fork" / "ed25519.key"
DEFAULT_CACHE = Path.home() / ".cache" / "nc-fork-appcast"


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def fetch_releases():
    """Return the releases of the repository, newest first."""
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    url = f"{API}/releases?per_page=50"
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except Exception:
        if shutil.which("gh") is None:
            raise
        out = run(["gh", "api", f"repos/{REPO}/releases?per_page=50"]).stdout
        return json.loads(out)


def version_tuple(tag):
    try:
        return tuple(int(part) for part in tag.lstrip("v").split(".")[:3])
    except ValueError:
        return (0,)


def pick_releases(releases, wanted_tag):
    stable = [r for r in releases if not r["draft"] and not r["prerelease"] and r["tag_name"].startswith("v")]
    if wanted_tag:
        stable = [r for r in stable if r["tag_name"] == wanted_tag]
    if not stable:
        sys.exit("no stable release found")
    stable.sort(key=lambda r: version_tuple(r["tag_name"]), reverse=True)
    nightly = next((r for r in releases if not r["draft"] and r["prerelease"] and r["tag_name"] == "nightly"), None)
    return stable[0], nightly


def download(asset, cache):
    target = cache / asset["name"]
    cache.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.stat().st_size == asset["size"]:
        return target
    print(f"downloading {asset['name']}", file=sys.stderr)
    tmp = target.with_suffix(target.suffix + ".part")
    with urllib.request.urlopen(asset["browser_download_url"], timeout=600) as response, open(tmp, "wb") as out:
        shutil.copyfileobj(response, out)
    tmp.rename(target)
    return target


def read_bundle_versions(dmg):
    """Mount the DMG and read the version keys of the application bundle inside it."""
    mount = tempfile.mkdtemp(prefix="nc-appcast-")
    attached = False
    try:
        run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, str(dmg)])
        attached = True
        for path in Path(mount).rglob("Contents/Info.plist"):
            with open(path, "rb") as file:
                info = plistlib.load(file)
            if "CFBundleVersion" in info:
                return {
                    "version": str(info["CFBundleVersion"]),
                    "short_version": str(info.get("CFBundleShortVersionString", "")),
                    "minimum_system": str(info.get("LSMinimumSystemVersion", "12.0")),
                }
        sys.exit(f"no application bundle inside {dmg}")
    finally:
        if attached:
            try:
                run(["hdiutil", "detach", mount])
            except subprocess.CalledProcessError:
                pass
        shutil.rmtree(mount, ignore_errors=True)


def sign(key_file, sign_update, archive):
    out = run([sign_update, "--ed-key-file", str(key_file), "-p", str(archive)]).stdout.strip()
    if not out:
        sys.exit(f"sign_update produced no signature for {archive}")
    return out


def make_item(release, cache, key_file, sign_update, channel=None):
    assets = [a for a in release["assets"] if a["name"].endswith(".dmg")]
    if not assets:
        sys.exit(f"release {release['tag_name']} has no .dmg asset")
    asset = assets[0]
    dmg = download(asset, cache)
    info = read_bundle_versions(dmg)
    signature = sign(key_file, sign_update, dmg)
    published = datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
    lines = [
        "    <item>",
        f"      <title>{escape(release['name'] or release['tag_name'])}</title>",
        f"      <link>{escape(release['html_url'])}</link>",
        f"      <pubDate>{email.utils.format_datetime(published.astimezone(timezone.utc))}</pubDate>",
        f"      <sparkle:version>{info['version']}</sparkle:version>",
        f"      <sparkle:shortVersionString>{escape(info['short_version'])}</sparkle:shortVersionString>",
        f"      <sparkle:minimumSystemVersion>{escape(info['minimum_system'])}</sparkle:minimumSystemVersion>",
        f"      <sparkle:releaseNotesLink>{escape(release['html_url'])}</sparkle:releaseNotesLink>",
    ]
    if channel:
        lines.append(f"      <sparkle:channel>{channel}</sparkle:channel>")
    lines += [
        f"      <enclosure url=\"{escape(asset['browser_download_url'])}\"",
        f"                 sparkle:edSignature=\"{signature}\"",
        f"                 length=\"{asset['size']}\"",
        '                 type="application/octet-stream" />',
        "    </item>",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", default=None, help="use this stable tag instead of the latest one")
    parser.add_argument("--key-file", default=os.environ.get("SPARKLE_ED_KEY_FILE", str(DEFAULT_KEY_FILE)))
    parser.add_argument("--sign-update", default=os.environ.get("SPARKLE_SIGN_UPDATE", "sign_update"))
    parser.add_argument("--cache", default=str(DEFAULT_CACHE))
    parser.add_argument("--no-nightly", action="store_true", help="do not include the nightly pre-release")
    parser.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "appcast.xml"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not Path(args.key_file).is_file():
        sys.exit(f"the Sparkle private key {args.key_file} does not exist")
    if shutil.which(args.sign_update) is None:
        sys.exit(f"the Sparkle sign_update tool {args.sign_update!r} is not on PATH")

    stable, nightly = pick_releases(fetch_releases(), args.tag)
    cache = Path(args.cache)

    items = [make_item(stable, cache, args.key_file, args.sign_update)]
    if nightly and not args.no_nightly:
        items.append(make_item(nightly, cache, args.key_file, args.sign_update, channel="nightly"))

    feed = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
        "  <channel>",
        "    <title>Nimble Commander-Fork</title>",
        f"    <link>https://github.com/{REPO}</link>",
        "    <description>Update feed for Nimble Commander-Fork. The items point at the DMG assets of",
        "      the GitHub releases of the fork; the nightly pre-release is kept in its own channel.</description>",
        "    <language>en</language>",
    ]
    feed += items
    feed += ["  </channel>", "</rss>", ""]
    text = "\n".join(feed)

    if args.dry_run:
        print(text)
    else:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
