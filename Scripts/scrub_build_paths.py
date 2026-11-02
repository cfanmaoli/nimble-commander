#!/usr/bin/env python3
# Copyright (C) 2026 The Nimble Commander-Fork Authors. Subject to GNU General Public License version 3.
"""Strip the local checkout path from the precompiled static libraries.

Third-party libraries are bootstrapped from a scratch directory inside the
repository (e.g. 3rd_Party/abseil/abseil.tmp/...), and the compilers record
those absolute paths in __FILE__ strings. Since the resulting libraries are
committed to the repository, the path of the machine that built them would
otherwise be published along with them.

The placeholder has to have exactly the same length as the original prefix,
so that the surrounding string data stays intact - the replacement is padded
with 'x' characters.

Usage:
    Scripts/scrub_build_paths.py            # scrub the whole checkout
    Scripts/scrub_build_paths.py --dry-run  # only report what would change
"""

import argparse
import os
import sys


def CheckoutRoot() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None, help="checkout root to scrub, defaults to the repository root")
    parser.add_argument("--placeholder", default="/nc-build/", help="replacement prefix, shorter than the checkout path")
    parser.add_argument("--dry-run", action="store_true", help="only report the files that would be changed")
    args = parser.parse_args()

    root = os.path.abspath(args.root or CheckoutRoot())
    needle = root.encode()
    placeholder = args.placeholder.encode()
    if len(placeholder) >= len(needle):
        sys.exit(f"placeholder {args.placeholder!r} must be shorter than the checkout path {root!r}")
    replacement = placeholder + b"x" * (len(needle) - len(placeholder))

    changed = 0
    occurrences = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for filename in filenames:
            if not filename.endswith(".a"):
                continue
            path = os.path.join(dirpath, filename)
            try:
                with open(path, "rb") as file:
                    data = file.read()
            except OSError:
                continue
            count = data.count(needle)
            if count == 0:
                continue
            changed += 1
            occurrences += count
            print(f"{os.path.relpath(path, root)}: {count}")
            if not args.dry_run:
                with open(path, "wb") as file:
                    file.write(data.replace(needle, replacement))

    verb = "would change" if args.dry_run else "changed"
    print(f"{verb} {changed} file(s), {occurrences} occurrence(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
