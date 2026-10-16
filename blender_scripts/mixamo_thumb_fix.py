"""
Thumb retarget fix for a Mixamo rig driven by the yellow hand (Quest Hands add-on).

Problem: Copy Rotation in Local Space copies "how much the bone turned around ITS OWN
axes". For the fingers both rigs have the same axes (Z = palm side), but the thumb is
different: yellow thumb Z = thumb pad, Mixamo thumb Z = down. The same rotation numbers
then bend the Mixamo thumb in the wrong plane.

Fix (one time, per side): in Edit Mode change the ROLL of the Mixamo thumb bones
(rotation around their own length) so that their Z axis points where the yellow thumb Z
points, measured relative to the hand. The bone stays in the same place, the mesh does not
move; only the bone's local axes turn. After that Local->Local Copy Rotation works.
Then the script adds the thumb constraints (named "QH Thumb", re-run safe).

Run: Scripting -> open this file -> set SIDES -> Alt+P (Object or Pose Mode).
"""
import bpy

SIDES = ("Right", "Left")         # which hands to fix
CHARACTER = "Armature"            # Mixamo armature object
PREFIX = "mixamorig1:"            # Mixamo bone prefix
TAG = "QH Thumb"

THUMB = [("HandThumb1", "ThumbMetacarpal"), ("HandThumb2", "ThumbProximal"),
         ("HandThumb3", "ThumbDistal"), ("HandThumb4", "ThumbTip")]


def yellow_for(side):
    prop = "quest_left_hand" if side == "Left" else "quest_right_hand"
    obj = getattr(bpy.context.scene, prop, None)
    return obj if obj is not None else bpy.data.objects.get(f"{side}HandHumanoid")


def main():
    char = bpy.data.objects.get(CHARACTER)
    if char is None or char.type != 'ARMATURE':
        raise RuntimeError(f"Mixamo armature '{CHARACTER}' not found")

    # ---- collect target Z axes (in Mixamo armature space) while in Object/Pose mode
    plan = {}
    for side in SIDES:
        yellow = yellow_for(side)
        if yellow is None:
            print(f"[QH thumb] {side}: yellow hand armature not found - skipped")
            continue
        yb, mb = yellow.data.bones, char.data.bones
        yh, mh = yb.get(f"{side}Hand"), mb.get(f"{PREFIX}{side}Hand")
        if yh is None or mh is None:
            print(f"[QH thumb] {side}: hand bone missing - skipped")
            continue
        yh_rot = yh.matrix_local.to_3x3().normalized()
        mh_rot = mh.matrix_local.to_3x3().normalized()
        for mix, yel in THUMB:
            ybone = yb.get(f"{side}{yel}")
            if ybone is None or mb.get(f"{PREFIX}{side}{mix}") is None:
                continue
            z_in_hand = yh_rot.transposed() @ ybone.matrix_local.to_3x3().normalized().col[2]
            plan[f"{PREFIX}{side}{mix}"] = (mh_rot @ z_in_hand, yellow, f"{side}{yel}")

    if not plan:
        raise RuntimeError("Nothing to do (no yellow hands / thumb bones found)")

    # ---- 1. change roll in Edit Mode
    prev_active = bpy.context.view_layer.objects.active
    prev_mode = char.mode
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.context.view_layer.objects.active = char
    bpy.ops.object.mode_set(mode='EDIT')
    for name, (z_target, _, _) in plan.items():
        eb = char.data.edit_bones[name]
        before = eb.roll
        eb.align_roll(z_target)
        print(f"[QH thumb] {name}: roll {before:+.3f} -> {eb.roll:+.3f} rad")
    bpy.ops.object.mode_set(mode='POSE')

    # ---- 2. thumb constraints (Local -> Local), rotations cleared
    for name, (_, yellow, ybone) in plan.items():
        pb = char.pose.bones[name]
        pb.rotation_mode = 'QUATERNION'
        pb.rotation_quaternion = (1, 0, 0, 0)
        for c in list(pb.constraints):
            if c.name.startswith("QH") or c.type == 'COPY_ROTATION':
                pb.constraints.remove(c)
        if name.endswith("Thumb4"):
            continue            # tip bone: roll aligned, no constraint needed
        c = pb.constraints.new('COPY_ROTATION')
        c.name = TAG
        c.target, c.subtarget = yellow, ybone
        c.mix_mode, c.owner_space, c.target_space = 'REPLACE', 'LOCAL', 'LOCAL'

    if prev_mode != 'POSE':
        bpy.ops.object.mode_set(mode='OBJECT')
    if prev_active is not None:
        bpy.context.view_layer.objects.active = prev_active
    print(f"[QH thumb] done: {len(plan)} thumb bones re-rolled, constraints added")


main()
