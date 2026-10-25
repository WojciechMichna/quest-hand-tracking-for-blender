#!/usr/bin/env python3
"""
Builds the Blender add-on release package:
    releases/QuestBodyAndHandsTracking_<tag>.zip

The zip contains QuestBodyAndHandsTracking/__init__.py (a copy of blender_addon/blender_hand_receiver.py),
so in Blender: Edit > Preferences > Add-ons > Install from Disk > pick the zip.

Version: from the git tag (`git describe --tags`).
  * HEAD exactly on a tag      -> v1.4.0          (bl_info "version" = (1, 4, 0))
  * commits after the tag      -> v1.4.0-3-gabc123
  * uncommitted changes        -> ...-dirty (warning; --strict aborts)

Usage:
    python make_release.py            # build
    python make_release.py --strict   # refuse unless the repo is clean and HEAD is on a tag
"""

import argparse
import os
import re
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(ROOT, "blender_addon", "blender_hand_receiver.py")
PACKAGE = "QuestBodyAndHandsTracking"
ADDON_NAME = "Quest Body and Hands Tracking"
# package names of earlier releases - Blender sees them as a different add-on, remove them before installing
OLD_PACKAGES = ("OculusQuestHandTracking",)
OUT_DIR = os.path.join(ROOT, "releases")


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True,
                                   stderr=subprocess.STDOUT).strip()


def get_version():
    try:
        tag = git("describe", "--tags", "--abbrev=0")
        full = git("describe", "--tags", "--dirty")
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        sys.exit(f"[release] git not found or no tags in the repo: {e}")
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", tag)
    if not m:
        sys.exit(f"[release] Tag '{tag}' does not contain an X.Y[.Z] version number")
    nums = tuple(int(x or 0) for x in m.groups())
    return tag, full, nums


def patch_bl_info(src, nums):
    src, n1 = re.subn(r'"version"\s*:\s*\([^)]*\)', f'"version": {nums}', src, count=1)
    src, n2 = re.subn(r'"name"\s*:\s*"[^"]*"', f'"name": "{ADDON_NAME}"', src, count=1)
    if not (n1 and n2):
        sys.exit("[release] bl_info (name/version) not found in the add-on source")
    return src


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true",
                    help="abort if HEAD is not on a tag or there are uncommitted changes")
    args = ap.parse_args()

    if not os.path.isfile(SOURCE):
        sys.exit(f"[release] File not found: {SOURCE}")

    tag, full, nums = get_version()
    exact = (full == tag)
    if not exact:
        msg = f"[release] WARNING: '{full}' - HEAD is not exactly on tag '{tag}' or there are uncommitted changes."
        if args.strict:
            sys.exit(msg + " (--strict)")
        print(msg)

    with open(SOURCE, encoding="utf-8") as f:
        src = patch_bl_info(f.read(), nums)
    compile(src, f"{PACKAGE}/__init__.py", "exec")   # syntax sanity check

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, f"{PACKAGE}_{full}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{PACKAGE}/__init__.py", src)

    print(f"[release] {out}")
    print(f"[release] add-on version: {nums}  (tag {tag})")
    print("[release] Blender: Edit > Preferences > Add-ons > Install from Disk > pick this zip")
    print(f"[release] Upgrading from {', '.join(OLD_PACKAGES)} (\"Oculus Quest Hand Tracking\", <= v1.8): remove "
          "that add-on first - both register the same operators and scene settings")


if __name__ == "__main__":
    main()
