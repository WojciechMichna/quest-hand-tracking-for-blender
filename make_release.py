#!/usr/bin/env python3
"""
Builds the release files into releases/:

    OculusQuestHandTracking_<tag>.zip        Blender add-on (Install from Disk)
    QuestHandTracking_<tag>_hands.blend      rigged hand armatures ready for the add-on
    QuestHandTracking_<tag>.apk              Quest app (only with --apk)

Add-on zip: OculusQuestHandTracking/__init__.py = blender_addon/blender_hand_receiver.py with
bl_info "version" taken from the git tag.

APK: exported with the Godot command line (preset "Android" from export_presets.cfg).
Godot needs: Android export templates, Android SDK/JDK set in Editor Settings, the
Godot OpenXR Vendors plugin in addons/, and the Android build template (android/build).
  --apk                      debug-signed APK (Godot's debug keystore) - fine for sideloading
  --apk --apk-release        release APK (needs a release keystore set in the export preset)
  --godot PATH               Godot executable (or env GODOT, or "godot" on PATH)

Version: from the git tag (`git describe --tags`).
  * HEAD exactly on a tag      -> v1.7.0          (bl_info "version" = (1, 7, 0))
  * commits after the tag      -> v1.7.0-3-gabc123
  * uncommitted changes        -> ...-dirty (warning; --strict aborts)

Usage:
    python make_release.py                                    # add-on zip + hands .blend
    python make_release.py --apk --godot "C:/Godot/Godot_v4.7.exe"
    python make_release.py --strict --apk                      # refuse unless clean and on a tag
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(ROOT, "blender_addon", "blender_hand_receiver.py")
HANDS_BLEND = os.path.join(ROOT, "blender_models", "BothHands.blend")
PRESETS = os.path.join(ROOT, "export_presets.cfg")
PACKAGE = "OculusQuestHandTracking"
ADDON_NAME = "Oculus Quest Hand Tracking"
APP_NAME = "QuestHandTracking"
GODOT_PRESET = "Android"
OUT_DIR = os.path.join(ROOT, "releases")


def log(msg):
    print(f"[release] {msg}")


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


def build_addon(full, nums):
    if not os.path.isfile(SOURCE):
        sys.exit(f"[release] File not found: {SOURCE}")
    with open(SOURCE, encoding="utf-8") as f:
        src = patch_bl_info(f.read(), nums)
    compile(src, f"{PACKAGE}/__init__.py", "exec")   # syntax sanity check
    out = os.path.join(OUT_DIR, f"{PACKAGE}_{full}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{PACKAGE}/__init__.py", src)
    log(f"add-on : {out}  (bl_info version {nums})")


def copy_hands(full):
    if not os.path.isfile(HANDS_BLEND):
        log(f"WARNING: {HANDS_BLEND} not found - hands .blend skipped")
        return
    out = os.path.join(OUT_DIR, f"{APP_NAME}_{full}_hands.blend")
    shutil.copyfile(HANDS_BLEND, out)
    log(f"hands  : {out}")


def preset_version_name():
    try:
        with open(PRESETS, encoding="utf-8") as f:
            m = re.search(r'^version/name="([^"]*)"', f.read(), re.M)
        return m.group(1) if m else ""
    except OSError:
        return ""


def find_godot(arg):
    for cand in (arg, os.environ.get("GODOT"), "godot", "godot4"):
        if cand and (os.path.isfile(cand) or shutil.which(cand)):
            return cand
    sys.exit("[release] Godot executable not found: pass --godot PATH or set env GODOT")


def build_apk(full, nums, godot_arg, release):
    tag_ver = ".".join(map(str, nums))
    pv = preset_version_name()
    if pv != tag_ver:
        log(f"WARNING: export_presets.cfg version/name = '{pv}', git tag = '{tag_ver}' "
            f"(the headset shows version/name; update it in Project > Export)")
    if not os.path.isdir(os.path.join(ROOT, "addons", "godotopenxrvendors")):
        sys.exit("[release] addons/godotopenxrvendors missing - install Godot OpenXR Vendors from the Asset Library")
    if not os.path.isdir(os.path.join(ROOT, "android", "build")):
        sys.exit("[release] android/build missing - in Godot: Project > Install Android Build Template")
    godot = find_godot(godot_arg)
    out = os.path.join(OUT_DIR, f"{APP_NAME}_{full}.apk")
    if os.path.exists(out):
        os.remove(out)
    mode = "--export-release" if release else "--export-debug"
    cmd = [godot, "--headless", "--path", ROOT, mode, GODOT_PRESET, out]
    log("godot  : " + " ".join(f'"{c}"' if " " in c else c for c in cmd))
    rc = subprocess.call(cmd, cwd=ROOT)
    if rc != 0 or not os.path.isfile(out):
        sys.exit(f"[release] APK export failed (exit {rc}) - see the Godot output above")
    log(f"apk    : {out}  ({os.path.getsize(out) / 1e6:.1f} MB, {'release' if release else 'debug'}-signed)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true",
                    help="abort unless HEAD is exactly on a tag and there are no uncommitted changes")
    ap.add_argument("--apk", action="store_true", help="also export the Quest APK with Godot")
    ap.add_argument("--apk-release", action="store_true", help="release-signed APK instead of debug")
    ap.add_argument("--godot", help="path to the Godot 4.7 executable")
    args = ap.parse_args()

    tag, full, nums = get_version()
    if full != tag:
        msg = f"WARNING: '{full}' - HEAD is not exactly on tag '{tag}' or there are uncommitted changes."
        if args.strict:
            sys.exit("[release] " + msg + " (--strict)")
        log(msg)

    os.makedirs(OUT_DIR, exist_ok=True)
    build_addon(full, nums)
    copy_hands(full)
    if args.apk:
        build_apk(full, nums, args.godot, args.apk_release)
    log("done - upload the files from releases/ to a GitHub release for tag " + tag)


if __name__ == "__main__":
    main()
