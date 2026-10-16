"""
Mixamo arm setup driven by the yellow hand (Quest Hands add-on), one side per run.

Creates on the Mixamo rig (constraints named "QH ..."; existing IK on <Side>ForeArm and
Copy Rotation on <Side>Hand / finger bones are replaced, so re-running is safe):
  1. Fingers   : Copy Rotation Local->Local, Index/Middle/Ring/Pinky 1-3 <- yellow phalanges
  2. Hand      : Copy Rotation World->World, <Side>Hand <- yellow <Side>Hand
  3. Arm IK    : IK on <Side>ForeArm, target yellow <Side>Hand, Chain 2, Use Tail
  4. Pole      : Empty "ElbowPole_<L/R>" (created or moved) 40 cm behind / 20 cm below the rest elbow,
                 Pole Angle found automatically (the angle at which turning IK on does
                 not twist the arm in its current pose)

Before running: the arm bones of that side must have cleared rotations (Alt+R), and the
elbow must not be perfectly straight (Mixamo rest pose has ~9 deg - that is enough).

Run: Scripting -> open this file -> set SIDE -> Alt+P.
"""
import bpy
import math
from mathutils import Vector

# ------------------------------------------------------------------ settings
SIDE = "Left"                     # "Left" or "Right"
CHARACTER = "Armature"            # Mixamo armature object
PREFIX = "mixamorig1:"            # Mixamo bone prefix
YELLOW = None                     # yellow hand armature; None = take it from the add-on panel,
                                  # falls back to "<Side>HandHumanoid"
POLE_BACK = 0.40                  # metres behind the elbow
POLE_DOWN = 0.20                  # metres below the elbow
INCLUDE_THUMB = False             # thumb axes differ between the rigs -> off
TAG = "QH"

FINGERS = [
    ("HandIndex1", "IndexProximal"), ("HandIndex2", "IndexIntermediate"), ("HandIndex3", "IndexDistal"),
    ("HandMiddle1", "MiddleProximal"), ("HandMiddle2", "MiddleIntermediate"), ("HandMiddle3", "MiddleDistal"),
    ("HandRing1", "RingProximal"), ("HandRing2", "RingIntermediate"), ("HandRing3", "RingDistal"),
    ("HandPinky1", "LittleProximal"), ("HandPinky2", "LittleIntermediate"), ("HandPinky3", "LittleDistal"),
]
THUMB = [("HandThumb1", "ThumbMetacarpal"), ("HandThumb2", "ThumbProximal"), ("HandThumb3", "ThumbDistal")]


def log(msg):
    print(f"[QH arm {SIDE}] {msg}")


def find_yellow(scene):
    if YELLOW:
        return bpy.data.objects.get(YELLOW)
    prop = "quest_left_hand" if SIDE == "Left" else "quest_right_hand"
    obj = getattr(scene, prop, None)
    if obj is not None:
        return obj
    return bpy.data.objects.get(f"{SIDE}HandHumanoid")


def clear_ours(pb, yellow, types=('COPY_ROTATION',)):
    """Removes our old constraints and any existing constraint of the given types
    (e.g. a manual IK/Copy Rotation made earlier) so the setup is not doubled."""
    for c in list(pb.constraints):
        if c.name.startswith(TAG) or c.type in types:
            pb.constraints.remove(c)


def world_rot(char, pb):
    return (char.matrix_world.to_3x3().normalized() @ pb.matrix.to_3x3().normalized()).to_quaternion()


def main():
    scene = bpy.context.scene
    char = bpy.data.objects.get(CHARACTER)
    yellow = find_yellow(scene)
    if char is None or char.type != 'ARMATURE':
        raise RuntimeError(f"Mixamo armature '{CHARACTER}' not found")
    if yellow is None or yellow.type != 'ARMATURE':
        raise RuntimeError(f"Yellow {SIDE.lower()} hand armature not found (set it in the Quest Hands panel)")
    yellow_hand_bone = f"{SIDE}Hand"
    if yellow.pose.bones.get(yellow_hand_bone) is None:
        raise RuntimeError(f"Bone '{yellow_hand_bone}' missing in {yellow.name}")

    P = lambda n: char.pose.bones.get(f"{PREFIX}{SIDE}{n}")
    arm, fore, hand = P("Arm"), P("ForeArm"), P("Hand")
    if not (arm and fore and hand):
        raise RuntimeError(f"Mixamo bones {PREFIX}{SIDE}Arm/ForeArm/Hand not found")

    # ---- 1. fingers
    pairs = FINGERS + (THUMB if INCLUDE_THUMB else [])
    n_f = 0
    for mix, yel in pairs:
        pb = P(mix)
        if pb is None or yellow.pose.bones.get(f"{SIDE}{yel}") is None:
            log(f"skip finger {mix} <- {SIDE}{yel} (bone missing)")
            continue
        clear_ours(pb, yellow)
        c = pb.constraints.new('COPY_ROTATION')
        c.name = f"{TAG} Finger"
        c.target, c.subtarget = yellow, f"{SIDE}{yel}"
        c.mix_mode, c.owner_space, c.target_space = 'REPLACE', 'LOCAL', 'LOCAL'
        n_f += 1

    # ---- 2. hand rotation
    clear_ours(hand, yellow)
    c = hand.constraints.new('COPY_ROTATION')
    c.name = f"{TAG} Hand Rotation"
    c.target, c.subtarget = yellow, yellow_hand_bone
    c.mix_mode, c.owner_space, c.target_space = 'REPLACE', 'WORLD', 'WORLD'

    # ---- 3. pole empty from the rest pose
    clear_ours(fore, yellow, types=('IK',))
    clear_ours(arm, yellow, types=('IK',))
    W = char.matrix_world
    elbow_rest = W @ char.data.bones[fore.name].head_local
    head_bone = char.data.bones.get(f"{PREFIX}Head")
    if head_bone is not None:   # Mixamo: Head bone +Z points where the character looks
        forward = (W.to_3x3() @ head_bone.matrix_local.to_3x3().col[2]).normalized()
        forward.z = 0.0
        forward.normalize()
    else:
        forward = Vector((0, -1, 0))
    pole_name = f"ElbowPole_{SIDE[0]}"
    pole = bpy.data.objects.get(pole_name)
    if pole is None:
        pole = bpy.data.objects.new(pole_name, None)
        pole.empty_display_type = 'PLAIN_AXES'
        pole.empty_display_size = 0.08
        scene.collection.objects.link(pole)
    pole.parent = None
    pole.location = elbow_rest - forward * POLE_BACK + Vector((0, 0, -POLE_DOWN))

    # ---- 4. IK with automatic pole angle
    bpy.context.view_layer.update()
    sh, el, wr = W @ arm.head, W @ fore.head, W @ fore.tail
    bend = math.degrees((el - sh).angle(wr - el))
    if bend < 1.0:
        log(f"WARNING: elbow is almost straight ({bend:.2f} deg) - IK with a pole may not bend. "
            f"Clear rotations (Alt+R) of {arm.name}/{fore.name} or add a small pre-bend.")

    ref_arm, ref_fore = world_rot(char, arm), world_rot(char, fore)
    tmp = bpy.data.objects.new("QH_tmp_wrist", None)
    scene.collection.objects.link(tmp)
    tmp.location = wr

    ik = fore.constraints.new('IK')
    ik.name = f"{TAG} Arm IK"
    ik.target = tmp
    ik.pole_target = pole
    ik.chain_count = 2
    ik.use_tail = True
    ik.use_stretch = False
    ik.iterations = 500

    def deviation(angle_deg):
        ik.pole_angle = math.radians(angle_deg)
        bpy.context.view_layer.update()
        return max(math.degrees(ref_arm.rotation_difference(world_rot(char, arm)).angle),
                   math.degrees(ref_fore.rotation_difference(world_rot(char, fore)).angle))

    best = min(range(-180, 180, 5), key=deviation)
    for step in (1.0, 0.1):
        cand = [best + step * k for k in range(-5, 6)]
        best = min(cand, key=deviation)
    err = deviation(best)
    best = ((best + 180.0) % 360.0) - 180.0
    ik.pole_angle = math.radians(best)

    ik.target = yellow
    ik.subtarget = yellow_hand_bone
    bpy.data.objects.remove(tmp, do_unlink=True)
    bpy.context.view_layer.update()

    log(f"fingers: {n_f} constraints (thumb {'on' if INCLUDE_THUMB else 'off'})")
    log(f"hand: Copy Rotation World <- {yellow.name}:{yellow_hand_bone}")
    log(f"IK on {fore.name}: target {yellow.name}:{yellow_hand_bone}, chain 2, pole {pole.name}, "
        f"pole angle {best:.1f} deg (rest twist {err:.2f} deg)")
    if err > 2.0:
        log("WARNING: no pole angle keeps the arm untwisted - check that the arm rotations are cleared.")


main()
