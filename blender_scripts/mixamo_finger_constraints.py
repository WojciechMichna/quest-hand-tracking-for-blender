"""
Mixamo finger retarget: copies finger bends from the yellow hand (Quest Hands add-on)
onto a Mixamo rig with bone constraints (Copy Rotation, Local Space -> Local Space).

Run in Blender: Scripting -> open this file -> Alt+P (safe to re-run: it first removes
the constraints it created earlier, they are all named "QH Finger").

Why Local Space works here: both rigs use the same bone axis convention for fingers
(+Y along the bone, +Z palm side, flexion = rotation about +X), so "how much the yellow
phalanx bent from its rest pose" can be copied 1:1 onto the Mixamo phalanx.
The thumb is OFF by default: its Z axis differs between the rigs (Mixamo: down,
yellow hand: thumb pad), so a plain Local copy bends it in the wrong plane.
"""
import bpy

# ------------------------------------------------------------------ settings
CHARACTER = "Armature"            # Mixamo armature object
SOURCE = "RightHandHumanoid"      # yellow hand armature driven by the add-on
PREFIX = "mixamorig1:"            # Mixamo bone prefix (mixamorig: / mixamorig1: ...)
SIDE = "Right"                    # "Right" or "Left"
INCLUDE_THUMB = False
TAG = "QH Finger"                 # name of every constraint this script creates

# Mixamo bone suffix -> yellow hand bone (without the side prefix)
FINGERS = {
    "Index":  [("HandIndex1", "IndexProximal"), ("HandIndex2", "IndexIntermediate"), ("HandIndex3", "IndexDistal")],
    "Middle": [("HandMiddle1", "MiddleProximal"), ("HandMiddle2", "MiddleIntermediate"), ("HandMiddle3", "MiddleDistal")],
    "Ring":   [("HandRing1", "RingProximal"), ("HandRing2", "RingIntermediate"), ("HandRing3", "RingDistal")],
    "Pinky":  [("HandPinky1", "LittleProximal"), ("HandPinky2", "LittleIntermediate"), ("HandPinky3", "LittleDistal")],
    "Thumb":  [("HandThumb1", "ThumbMetacarpal"), ("HandThumb2", "ThumbProximal"), ("HandThumb3", "ThumbDistal")],
}


def main():
    char = bpy.data.objects.get(CHARACTER)
    src = bpy.data.objects.get(SOURCE)
    if char is None or char.type != 'ARMATURE':
        raise RuntimeError(f"Armature '{CHARACTER}' not found")
    if src is None or src.type != 'ARMATURE':
        raise RuntimeError(f"Armature '{SOURCE}' not found")

    added, skipped = 0, []
    for finger, pairs in FINGERS.items():
        if finger == "Thumb" and not INCLUDE_THUMB:
            continue
        for mixamo_suffix, yellow_short in pairs:
            owner = char.pose.bones.get(f"{PREFIX}{SIDE}{mixamo_suffix}")
            target_bone = f"{SIDE}{yellow_short}"
            if owner is None or src.pose.bones.get(target_bone) is None:
                skipped.append(f"{PREFIX}{SIDE}{mixamo_suffix} <- {target_bone}")
                continue
            # remove our old constraint and any manual Copy Rotation from the same source
            for c in list(owner.constraints):
                if c.name.startswith(TAG) or (c.type == 'COPY_ROTATION' and c.target == src):
                    owner.constraints.remove(c)
            c = owner.constraints.new('COPY_ROTATION')
            c.name = TAG
            c.target = src
            c.subtarget = target_bone
            c.mix_mode = 'REPLACE'
            c.owner_space = 'LOCAL'
            c.target_space = 'LOCAL'
            added += 1

    print(f"[QH] {added} finger constraints added ({SIDE}, thumb={'on' if INCLUDE_THUMB else 'off'})")
    for s in skipped:
        print(f"[QH] skipped (bone missing): {s}")


main()
