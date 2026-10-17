"""
Blender Live Hand Tracking Receiver (Meta Quest 3 / Godot -> Blender)
=====================================================================

Retargeting calibrated from the armature REST POSE (no hand-guessed quaternion
component swaps, independent of bone roll in GEOMETRIC mode).

Data convention coming from Godot (verified on recorded frames):
  * every joint frame (Godot skeleton convention, NOT raw OpenXR):
                         +Y = along the bone (towards the finger tip)
                         +Z = PALM side of the hand (positive rotation about +X = flexion)
                         +X = Y x Z  (right hand: towards the thumb, left hand: towards the little finger)
  * joint "rot" = parent^-1 * joint  (relative to the parent joint; for metacarpals = the wrist)
  * joint "pos" = joint position in the parent joint frame (metres), like BONE_UPDATE_FULL
  * wrist: position + rotation in XROrigin space (Godot: +Y up, -Z forward)

Rig modes:
  * NATIVE    - rig bone axes already follow the data convention (e.g. Godot's
                RightHandHumanoid/LeftHandHumanoid): Quest rotations go straight onto the
                bones, exactly like XRHandModifier3D in the headset.
  * GEOMETRIC - any rig: a reference frame per bone (Qref) is computed from the rest pose
                geometry (bone direction + palm side), live delta D = G * Qref^-1.
  * AUTO      - NATIVE when bone Z axes point to the palm side (avg < NATIVE_MAX_DEG).

Armature object: world = T(Godot->Blender) * Wrist * Fw^-1.

Install: Edit > Preferences > Add-ons > Install from Disk (this .py / the release zip)
         or Scripting -> Run Script (Alt+P) - re-running is safe.
Panel: 3D Viewport > Sidebar (N) > "Quest Hands" tab (Start/Stop).
"""

bl_info = {
    "name": "Oculus Quest Hand Tracking",
    "author": "Wojciech Michna",
    "version": (1, 7, 0),
    "blender": (4, 2, 0),
    "location": "3D Viewport > Sidebar (N) > Quest Hands",
    "description": "Live hand tracking from Meta Quest 3 (Godot app, UDP) onto hand armatures",
    "category": "Animation",
}

import bpy
import socket
import json
import threading
import math
import time
import os
import collections
import struct
from mathutils import Matrix, Quaternion, Vector

# ----------------------------------------------------------------- configuration
PORT = 5005
# On Stop the last HISTORY_SECONDS seconds of raw packets are written to quest_last_frames.jsonl
HISTORY_SECONDS = 10.0
HISTORY_MAX_PACKETS = 2000


def output_dir():
    """Folder for dumps: next to the saved .blend file, otherwise ~/QuestHandTracking."""
    base = bpy.path.abspath("//") if bpy.data.filepath else os.path.join(os.path.expanduser("~"), "QuestHandTracking")
    os.makedirs(base, exist_ok=True)
    return base
SIDES = ("Right", "Left")

# Scale of tracked positions in the Blender world (1.0 = metres 1:1)
# (reference points for head/hands are set in the panel: Head Origin / Hands Origin)
WORLD_SCALE = 1.0

# Godot (+X right, +Y up, -Z forward) -> Blender (+X right, +Y forward, +Z up)
T_G2B = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))

FINGERS = {
    "Thumb":  ["ThumbMetacarpal", "ThumbProximal", "ThumbDistal", "ThumbTip"],
    "Index":  ["IndexMetacarpal", "IndexProximal", "IndexIntermediate", "IndexDistal", "IndexTip"],
    "Middle": ["MiddleMetacarpal", "MiddleProximal", "MiddleIntermediate", "MiddleDistal", "MiddleTip"],
    "Ring":   ["RingMetacarpal", "RingProximal", "RingIntermediate", "RingDistal", "RingTip"],
    "Little": ["LittleMetacarpal", "LittleProximal", "LittleIntermediate", "LittleDistal", "LittleTip"],
}

# GEOMETRIC mode only:
# True  = finger metacarpals (Index..Little) stay in the model rest pose and fingers bend around the
#         model's geometric axes (stable, the little finger does not drift sideways).
# False = metacarpals are tracked from the Quest too (palm arch), but the little finger may drift.
FREEZE_FINGER_METACARPALS = True
# NATIVE mode with "Joints: From model": Index..Little metacarpals stay in rest pose and phalanges get
# the FULL (from the wrist) Quest orientation. Quest/Godot (BONE_UPDATE_FULL) places finger roots at their
# real positions; with rotations only, the rotated metacarpal (little finger ~25°) would drag the finger.
NATIVE_FREEZE_METACARPALS = True
# AUTO: the rig counts as NATIVE when finger bone Z axes deviate from the palm side by less than this (avg)
NATIVE_MAX_DEG = 20.0

# Metacarpal orientations reported by the Quest (relative to the wrist) for the RIGHT hand.
# (x, y, z, w). Left = mirror: (x, -y, -z, w)
QUEST_METACARPAL_REST = {
    "IndexMetacarpal":  (0.0, 0.0, 0.0, 1.0),
    "MiddleMetacarpal": (0.0, 0.0, 0.0, 1.0),
    "RingMetacarpal":   (0.0, 0.0, 0.0, 1.0),
    "LittleMetacarpal": (0.0183, 0.207, 0.1403, 0.968),
}
# Approximate direction of the thumb pad (+Z of its frame) in the wrist frame, right hand.
THUMB_INNER_HINT_RIGHT = Vector((-0.8, 0.5, 0.25))


# ----------------------------------------------------------------- math
def _q(r):
    """[x, y, z, w] -> mathutils.Quaternion"""
    return Quaternion((r[3], r[0], r[1], r[2]))


def _mirror_q(r):
    x, y, z, w = r
    return (x, -y, -z, w)


def _frame(fwd, hint):
    """3x3 matrix in the data convention: column Y = fwd, Z = hint (orthogonalised)."""
    y = fwd.normalized()
    z = hint - y * hint.dot(y)
    if z.length < 1e-6:
        z = Vector((0, 0, 1)) if abs(y.z) < 0.9 else Vector((1, 0, 0))
        z = z - y * z.dot(y)
    z.normalize()
    x = y.cross(z)
    return Matrix((x, y, z)).transposed()


# ----------------------------------------------------------------- packet decoding
QHND_MAGIC = b"QHND"
QHND_VERSION = 1
# fixed joint order of the binary format (same order as FINGER_CHAINS in hand_streamer.gd)
JOINT_ORDER = [(finger.lower(), name) for finger, chain in FINGERS.items() for name in chain]


def decode_packet(data):
    """bytes -> frame dict (same structure for binary QHND and legacy JSON)."""
    if data[:4] == QHND_MAGIC:
        return _decode_qhnd(data)
    if data[:1] == b"{":
        return json.loads(data.decode("utf-8"))
    raise ValueError(f"unknown packet ({len(data)} B, starts with {data[:4]!r})")


def _decode_qhnd(data):
    ver, flags, jc, t = struct.unpack_from("<BBHI", data, 4)
    if ver != QHND_VERSION:
        raise ValueError(f"unsupported QHND version {ver} (add-on supports {QHND_VERSION})")
    if jc != len(JOINT_ORDER):
        raise ValueError(f"QHND joint count {jc} != {len(JOINT_ORDER)}")
    off = 12
    frame = {"time": t}
    if flags & 1:
        v = struct.unpack_from("<7f", data, off)
        off += 28
        frame["head"] = {"pos": list(v[:3]), "rot": list(v[3:])}
    for bit, key in ((2, "left"), (4, "right")):
        if not flags & bit:
            continue
        (mask,) = struct.unpack_from("<I", data, off)
        off += 4
        w = struct.unpack_from("<7f", data, off)
        off += 28
        js = struct.unpack_from(f"<{jc * 7}f", data, off)
        off += jc * 28
        mr = None
        if flags & 8:
            mr = struct.unpack_from(f"<{jc * 4}f", data, off)
            off += jc * 16
        chains = {}
        for i, (finger, name) in enumerate(JOINT_ORDER):
            e = {"name": name, "rot": list(js[i * 7:i * 7 + 4]), "pos": list(js[i * 7 + 4:i * 7 + 7]),
                 "valid": bool((mask >> i) & 1)}
            if mr is not None:
                e["model_rot"] = list(mr[i * 4:i * 4 + 4])
            chains.setdefault(finger, []).append(e)
        frame[key] = {"wrist": {"pos": list(w[:3]), "rot": list(w[3:])}, "chains": chains}
    return frame


class HandCalibration:
    """Everything derived from the rest pose of one armature."""

    def __init__(self, arm_obj, side, mode="AUTO"):
        self.side = side
        self.mode = "GEOMETRIC"
        self.ok = False
        bones = arm_obj.data.bones
        prefix = detect_bone_prefix(arm_obj, side)
        self.bone_prefix = prefix
        if prefix is None:
            print(f"[QuestReceiver] {arm_obj.name}: no *IndexProximal bone found - skipping")
            return
        P = lambda n: bones.get(prefix + n)

        root = P("Hand")
        idx, mid, lit = P("IndexProximal"), P("MiddleProximal"), P("LittleProximal")
        if not (idx and mid and lit):
            print(f"[QuestReceiver] {arm_obj.name}: missing {prefix}Index/Middle/LittleProximal bones - skipping")
            return

        wrist_pos = root.head_local.copy() if root else (idx.head_local + lit.head_local) * 0.5
        fingers_dir = (mid.head_local - wrist_pos).normalized()
        toward_thumb = (idx.head_local - lit.head_local).normalized()
        # data convention: right X -> thumb, left X -> little finger
        x_axis = toward_thumb if side == "Right" else -toward_thumb
        y_axis = fingers_dir
        x_axis = (x_axis - y_axis * x_axis.dot(y_axis)).normalized()
        z_axis = x_axis.cross(y_axis)  # palm side
        self.Fw = Matrix((x_axis, y_axis, z_axis)).transposed()   # data wrist frame -> armature
        self.FwT = self.Fw.transposed()
        Fw4 = self.Fw.to_4x4()
        Fw4.translation = wrist_pos
        self.Fw4_inv = Fw4.inverted()

        palm_hint = Vector((0, 0, 1))
        thumb_hint = THUMB_INNER_HINT_RIGHT.copy()
        if side == "Left":
            thumb_hint.x = -thumb_hint.x

        # Qref (3x3 matrices in the data wrist frame) for every bone
        self.qref_inv = {}
        self.frozen = {}
        self.skip_delta = set()
        for finger, chain in FINGERS.items():
            parent_ref = None
            parent_geo = None
            for short in chain:
                b = P(short)
                if not b:
                    continue
                d = self.FwT @ (b.tail_local - b.head_local)
                if parent_geo is None:
                    hint = thumb_hint if finger == "Thumb" else palm_hint
                else:
                    hint = parent_geo.col[2].to_3d()
                geo = _frame(d, hint)
                if parent_geo is None:
                    if short in QUEST_METACARPAL_REST and FREEZE_FINGER_METACARPALS:
                        ref = geo
                        self.frozen[short] = geo     # live: metacarpal G := model rest
                    elif short in QUEST_METACARPAL_REST:
                        r = QUEST_METACARPAL_REST[short]
                        if side == "Left":
                            r = _mirror_q(r)
                        ref = _q(r).to_matrix()
                    else:
                        ref = geo
                else:
                    # constant "Quest frame vs geometric frame" offset in the bone LOCAL space
                    ref = geo @ (parent_geo.transposed() @ parent_ref)
                self.qref_inv[short] = ref.transposed()
                parent_ref, parent_geo = ref, geo

        # bone order: parent before child
        self.order = [b.name for b in arm_obj.data.bones]
        self.rest = {b.name: b.matrix_local.copy() for b in arm_obj.data.bones}
        self.rest_inv = {n: m.inverted() for n, m in self.rest.items()}
        self.parent = {b.name: (b.parent.name if b.parent else None) for b in arm_obj.data.bones}
        self.ok = True

        # --- NATIVE mode: rig bone axes = data convention (e.g. Godot's RightHandHumanoid).
        # Each bone then gets exactly the Quest rotation (like XRHandModifier3D in Godot):
        # Fw = wrist bone rest, Qref = bone rest in the wrist frame.
        self.native_score = self._native_score(P, root)
        use_native = (mode == "NATIVE") or (mode == "AUTO" and self.native_score is not None
                                             and self.native_score < NATIVE_MAX_DEG)
        if use_native and root is not None:
            Rw = root.matrix_local.to_3x3().normalized()
            self.Fw = Rw
            self.FwT = Rw.transposed()
            self.Fw4_inv = root.matrix_local.normalized().inverted()
            self.qref_inv = {}
            for chain in FINGERS.values():
                for short in chain:
                    b = P(short)
                    if b:
                        self.qref_inv[short] = (self.FwT @ b.matrix_local.to_3x3().normalized()).transposed()
            self.frozen = {}
            self.skip_delta = set(QUEST_METACARPAL_REST) if NATIVE_FREEZE_METACARPALS else set()
            self.mode = "NATIVE"

    def _native_score(self, P, root):
        """Average angle [deg] between bone Z axes and the palm side (from geometry).
        Small = rig axes follow the Quest data convention (Godot humanoid hand)."""
        if root is None:
            return None
        palm = self.Fw.col[2].to_3d()          # palm side in armature space (geometry)
        angs = []
        for f, chain in FINGERS.items():
            if f == "Thumb":
                continue
            for short in chain[1:4]:
                b = P(short)
                if b:
                    z = b.matrix_local.to_3x3().normalized().col[2].to_3d()
                    y = b.matrix_local.to_3x3().normalized().col[1].to_3d()
                    pz = (palm - y * palm.dot(y))
                    if pz.length > 1e-6:
                        angs.append(math.degrees(z.angle(pz.normalized())))
        return sum(angs) / len(angs) if angs else None


def detect_bone_prefix(arm_obj, side):
    """Bone name prefix: 'Right'/'Left' by side, otherwise any '<X>IndexProximal'."""
    bones = arm_obj.data.bones
    other = "Left" if side == "Right" else "Right"
    for pre in (side, other):
        if bones.get(pre + "IndexProximal"):
            return pre
    for b in bones:
        if b.name.endswith("IndexProximal"):
            return b.name[: -len("IndexProximal")]
    return None


_calib = {}


def _get_calib(arm_obj, side):
    key = (arm_obj.name, side)
    c = _calib.get(key)
    if c is None:
        mode = getattr(bpy.context.scene, "quest_rig_mode", "AUTO") if bpy.context.scene else "AUTO"
        c = HandCalibration(arm_obj, side, mode)
        print(f"[QuestReceiver] {arm_obj.name}: mode {c.mode} (axis match {c.native_score if c.native_score is None else round(c.native_score, 1)} deg)")
        _calib[key] = c
    return c


def _room_matrix(pos, rot):
    """Quest pose (Godot room space) -> 4x4 in Blender axes, without an anchor."""
    M = (T_G2B @ _q(rot).to_matrix()).to_4x4() if rot else Matrix.Identity(4)
    M.translation = T_G2B @ Vector(pos) * WORLD_SCALE
    return M


def _no_scale(m):
    loc, rot, _ = m.decompose()
    return Matrix.LocRotScale(loc, rot, None)


def _anchor(obj):
    """Anchor matrix (object location + rotation, no scale); no object = world origin."""
    return _no_scale(obj.matrix_world) if obj is not None else Matrix.Identity(4)


def _update_armature(arm_obj, hand, side, wrist_world, quest_positions=False):
    """wrist_world: target wrist matrix in the Blender world (Quest data axes).
    quest_positions: True = joint positions from the Quest ('pos' field, like BONE_UPDATE_FULL in Godot),
                     False = bone positions/lengths from the model (rotations only)."""
    cal = _get_calib(arm_obj, side)
    if not cal.ok or not hand:
        return
    prefix = cal.bone_prefix

    # 1. Armature object = wrist
    if wrist_world is not None:
        arm_obj.matrix_world = wrist_world @ Matrix.Scale(WORLD_SCALE, 4) @ cal.Fw4_inv

    # 2. Bone delta rotations in armature space
    # old APK without the "pos" field -> behave like "From model"
    # all positions zero (tracker gave orientations only, e.g. controller-driven hand data)
    # -> also fall back, otherwise every bone collapses onto the wrist
    quest_positions = quest_positions and any(
        sum(abs(x) for x in info.get("pos", (0.0, 0.0, 0.0))) > 1e-4
        for ch in (hand.get("chains") or {}).values() for info in ch)
    delta = {}
    heads = {}       # target bone head positions in armature space (quest_positions mode)
    wrist_head = cal.Fw4_inv.inverted().translation
    for chain in (hand.get("chains") or {}).values():
        G = Matrix.Identity(3)       # orientation used for the bone (may be frozen)
        Gq = Matrix.Identity(3)      # true Quest joint orientation (for positions)
        p = wrist_head.copy()        # parent joint position (armature space)
        for info in chain:
            short = info.get("name", "")
            if quest_positions and "pos" in info:
                p = p + cal.Fw @ (Gq @ Vector(info["pos"]))
                heads[prefix + short] = p.copy()
            rq = _q(info["rot"]).to_matrix()
            Gq = Gq @ rq
            fz = cal.frozen.get(short) if not quest_positions else None
            G = fz.copy() if fz is not None else G @ rq
            qi = cal.qref_inv.get(short)
            skip = (short in cal.skip_delta) and not quest_positions
            if qi is not None and not skip:
                delta[prefix + short] = cal.Fw @ (G @ qi) @ cal.FwT

    # 3. matrix_basis in hierarchy order
    live = {}
    pbones = arm_obj.pose.bones
    for name in cal.order:
        rest = cal.rest[name]
        par = cal.parent[name]
        # transform "attached" to the parent (without its own rotation)
        attached = (live[par] @ cal.rest_inv[par] @ rest) if par else rest.copy()
        D = delta.get(name)
        if D is not None:
            L = (D @ rest.to_3x3()).to_4x4()
            L.translation = attached.translation
        else:
            L = attached.copy()
        h = heads.get(name)
        if h is not None:
            L.translation = h
        live[name] = L
        pb = pbones.get(name)
        if pb is not None:
            basis = attached.inverted() @ L
            pb.rotation_mode = 'QUATERNION'
            pb.rotation_quaternion = basis.to_quaternion()
            pb.location = basis.to_translation() if h is not None else (0, 0, 0)


def _update_head(obj, head_world):
    """Headset position + rotation. Object local axes = headset axes:
    -Z = view direction, +Y = up (like a Blender Camera). Object scale is kept."""
    _, _, scale = obj.matrix_world.decompose()
    loc, rot, _ = head_world.decompose()
    obj.matrix_world = Matrix.LocRotScale(loc, rot, scale)


def _ok(scene, o):
    return o if (o is not None and o.name in scene.objects) else None


def get_targets(scene):
    """Objects from the scene settings (None when empty or not in the scene)."""
    arm = lambda o: o if (_ok(scene, o) and o.type == 'ARMATURE') else None
    g = lambda n: getattr(scene, n, None)
    return {
        "Right": arm(g("quest_right_hand")),
        "Left": arm(g("quest_left_hand")),
        "Head": _ok(scene, g("quest_head")),
        "HeadOrigin": _ok(scene, g("quest_head_origin")),
        "HandsOrigin": _ok(scene, g("quest_hands_origin")),
        "HandsToHead": bool(g("quest_hands_relative_to_head")),
    }


_last_head_room = {"m": None}


def _recenter(scene):
    """Recenter correction C (stored in the scene): head_world = HeadOrigin * C * head_room.
    Identity when not set."""
    v = scene.get("quest_recenter")
    if v is None or len(v) != 16:
        return Matrix.Identity(4)
    return Matrix([list(v[0:4]), list(v[4:8]), list(v[8:12]), list(v[12:16])])


def compute_recenter(head_room):
    """C so that the CURRENT head stands above the origin (x = y = 0, height kept)
    and looks along +Y of Head Origin - the same convention as the Quest app's own recenter
    (Quest forward -Z -> Blender +Y). A character facing -Y needs Head Origin rotated 180 deg on Z.
    Only yaw is used."""
    import math
    fwd = head_room.to_3x3() @ Vector((0.0, 0.0, -1.0))
    if fwd.x * fwd.x + fwd.y * fwd.y < 1e-8:          # looking straight up/down - use the up axis
        fwd = head_room.to_3x3() @ Vector((0.0, 1.0, 0.0))
    yaw = math.atan2(fwd.y, fwd.x)
    R = Matrix.Rotation(math.pi / 2.0 - yaw, 4, 'Z')
    p = R @ head_room.translation
    return Matrix.Translation((-p.x, -p.y, 0.0)) @ R


def apply_frame(frame, scene=None):
    """Head:  world = HeadOrigin * head_room
    Hands relative to head: world = Head(object, no scale) * head_room^-1 * hand_room
            (no Head object: virtual head = HeadOrigin * head_room)
    Hands not relative:     world = HandsOrigin * hand_room
    No Origin object = Blender world origin."""
    scene = scene or bpy.context.scene
    t = get_targets(scene)

    head = frame.get("head") or {}
    if "pos" in head:
        _last_head_room["m"] = _room_matrix(head["pos"], head.get("rot"))
    head_room = _last_head_room["m"]

    head_world = None
    if head_room is not None:
        head_world = _anchor(t["HeadOrigin"]) @ _recenter(scene) @ head_room
        if t["Head"] is not None:
            _update_head(t["Head"], head_world)

    if t["HandsToHead"]:
        if head_room is None:
            hands_base = None      # no head data yet - do not move the hands
        else:
            head_now = _no_scale(t["Head"].matrix_world) if t["Head"] is not None else head_world
            hands_base = head_now @ head_room.inverted()
    else:
        hands_base = _anchor(t["HandsOrigin"]) @ _recenter(scene)

    lost_mode = getattr(scene, "quest_lost_hand", "HOLD")
    for side in SIDES:
        obj = t[side]
        hand = frame.get(side.lower())
        if obj is None or obj.hide_viewport:
            continue
        if not hand:
            _on_hand_lost(obj, side, lost_mode)
            continue
        _on_hand_found(obj, side)
        hand = _hold_invalid_joints(hand, side)
        w = hand.get("wrist")
        wrist_world = (hands_base @ _room_matrix(w["pos"], w["rot"])) if (w and hands_base is not None) else None
        _update_armature(obj, hand, side, wrist_world,
                         getattr(scene, "quest_joint_positions", "QUEST") == "QUEST")


_last_good = {"Right": {}, "Left": {}}      # side -> {joint name: last valid entry}
_hand_lost = {"Right": False, "Left": False}
_hidden_by_us = {"Right": [], "Left": []}


def _hold_invalid_joints(hand, side):
    """Joints flagged invalid by the tracker keep their last valid rotation/position."""
    good = _last_good[side]
    chains = hand.get("chains") or {}
    if all(info.get("valid", True) for ch in chains.values() for info in ch):
        for ch in chains.values():
            for info in ch:
                good[info["name"]] = info
        return hand
    out = dict(hand)
    out["chains"] = {}
    for finger, ch in chains.items():
        new = []
        for info in ch:
            if info.get("valid", True):
                good[info["name"]] = info
                new.append(info)
            else:
                prev = good.get(info["name"])
                new.append(prev if prev is not None else info)
        out["chains"][finger] = new
    return out


def _on_hand_lost(obj, side, mode):
    if _hand_lost[side]:
        return
    _hand_lost[side] = True
    if mode == "HIDE":
        objs = [obj] + list(obj.children_recursive)
        for o in objs:
            if not o.hide_get():
                o.hide_set(True)
                _hidden_by_us[side].append(o.name)
    elif mode == "REST":
        for pb in obj.pose.bones:
            pb.rotation_mode = 'QUATERNION'
            pb.rotation_quaternion = (1, 0, 0, 0)
            pb.location = (0, 0, 0)


def _on_hand_found(obj, side):
    if not _hand_lost[side]:
        return
    _hand_lost[side] = False
    _unhide(side)


def _unhide(side):
    for name in _hidden_by_us[side]:
        o = bpy.data.objects.get(name)
        if o is not None:
            try:
                o.hide_set(False)
            except RuntimeError:
                pass
    _hidden_by_us[side] = []


def _reset_hand_state():
    for side in SIDES:
        _unhide(side)
        _hand_lost[side] = False
        _last_good[side] = {}


def compare_model(frame, scene=None):
    """DEBUG: compare with the headset model bones ('model_rot' field from Godot).
    Returns {side: (tracker_vs_model_deg, bone, blender_vs_model_deg, bone)} or {}."""
    scene = scene or bpy.context.scene
    t = get_targets(scene)
    out = {}
    for side in SIDES:
        hand = frame.get(side.lower())
        if not hand:
            continue
        obj = t[side]
        cal = _calib.get((obj.name, side)) if obj else None
        worst_t, worst_b = (0.0, "-"), (0.0, "-")
        found = False
        for chain in (hand.get("chains") or {}).values():
            for info in chain:
                mr = info.get("model_rot")
                if mr is None:
                    continue
                found = True
                qm = _q(mr)
                a = math.degrees(_q(info["rot"]).rotation_difference(qm).angle)
                if a > worst_t[0]:
                    worst_t = (a, info["name"])
                if cal is not None and cal.ok:
                    name = cal.bone_prefix + info["name"]
                    pb = obj.pose.bones.get(name)
                    if pb is not None:
                        b = pb.bone
                        rest_local = (b.parent.matrix_local.inverted() @ b.matrix_local) if b.parent else b.matrix_local
                        q_bl = (rest_local.to_3x3().normalized() @ pb.matrix_basis.to_3x3().normalized()).to_quaternion()
                        a2 = math.degrees(q_bl.rotation_difference(qm).angle)
                        if a2 > worst_b[0]:
                            worst_b = (a2, info["name"])
        if found:
            out[side] = (worst_t[0], worst_t[1], worst_b[0], worst_b[1])
    return out


def apply_dump(filename="quest_dump.json", scene=None):
    path = filename if os.path.isabs(filename) else os.path.join(output_dir(), filename)
    with open(path, encoding="utf-8") as f:
        apply_frame(json.load(f), scene)
    print(f"[QuestReceiver] Applied frame from {path}")


def reset_pose(scene=None):
    t = get_targets(scene or bpy.context.scene)
    for side in SIDES:
        obj = t[side]
        if obj:
            for pb in obj.pose.bones:
                pb.rotation_mode = 'QUATERNION'
                pb.rotation_quaternion = (1, 0, 0, 0)
                pb.location = (0, 0, 0)
            obj.matrix_world = Matrix.Identity(4)


# ----------------------------------------------------------------- network
KILL_MAGIC = b"QUEST_RECEIVER_KILL:"
_STATE_KEY = "quest_hand_receiver_state"


def _state():
    """State kept outside the module (driver_namespace) so it survives
    re-running the script / reloading the add-on."""
    ns = bpy.app.driver_namespace
    st = ns.get(_STATE_KEY)
    if st is None:
        st = {"thread": None, "timer": None, "status": "Stopped"}
        ns[_STATE_KEY] = st
    return st


class HandReceiverThread(threading.Thread):
    """UDP thread. The socket is bound on the main thread (so Start can report
    an error); the thread exits when it receives the KILL_MAGIC+token packet."""

    def __init__(self, sock, port):
        super().__init__(name="QuestHandReceiverThread", daemon=True)
        self.sock = sock
        self.port = port
        self.token = os.urandom(8).hex().encode()
        self.running = True
        self.lock = threading.Lock()
        self.latest_frame = None
        self.has_new_frame = False
        self.packets = 0
        self.bad_packets = 0
        self.last_error = ""
        self.last_format = "-"
        self.last_size = 0
        # raw packets from the last ~HISTORY_SECONDS (written to a file on Stop)
        self.history = collections.deque(maxlen=HISTORY_MAX_PACKETS)

    def run(self):
        kill = KILL_MAGIC + self.token
        print(f"[QuestReceiver] Listening on UDP port {self.port}")
        while self.running:
            try:
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            if data == kill:
                break
            try:
                pkt = decode_packet(data)
            except Exception as e:
                self.bad_packets += 1
                self.last_error = str(e)
                continue
            self.last_format = "QHND" if data[:4] == QHND_MAGIC else "JSON"
            self.last_size = len(data)
            self.history.append((time.time(), pkt))
            with self.lock:
                self.latest_frame = pkt
                self.has_new_frame = True
                self.packets += 1
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass
        print("[QuestReceiver] UDP thread finished.")

    def kill(self, timeout=1.0):
        """Sends the kill packet to its own port and waits for the thread to finish."""
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.sendto(KILL_MAGIC + self.token, ("127.0.0.1", self.port))
            s.close()
        except OSError:
            pass
        self.join(timeout=timeout)
        if self.is_alive():           # fallback: flag + socket timeout
            self.running = False
            self.join(timeout=timeout)

    def get_latest_frame(self):
        with self.lock:
            if not self.has_new_frame:
                return None
            self.has_new_frame = False
            return self.latest_frame


def _flex_deg(chain, i):
    try:
        x = chain[i]["rot"][0]
        return math.degrees(2.0 * math.asin(max(-1.0, min(1.0, x))))
    except Exception:
        return 0.0


def _tag_redraw():
    wm = getattr(bpy.context, "window_manager", None)
    if not wm:
        return
    for win in wm.windows:
        for area in win.screen.areas:
            if area.type == 'VIEW_3D':
                area.tag_redraw()


def _make_timer():
    log = {"t": time.time(), "p": 0}

    def timer_callback():
        st = _state()
        th = st.get("thread")
        if th is None or not th.is_alive():
            st["timer"] = None
            st["status"] = "Stopped"
            _tag_redraw()
            return None
        frame = th.get_latest_frame()
        if frame:
            try:
                scene = bpy.data.scenes.get(st.get("scene") or "") or bpy.context.scene
                apply_frame(frame, scene)
                st["last_frame"] = frame      # exactly the frame the current bone poses come from
            except Exception as e:
                print(f"[QuestReceiver] Error applying frame: {e}")
        now = time.time()
        if now - log["t"] >= 1.0:
            fps = (th.packets - log["p"]) / (now - log["t"])
            log["t"], log["p"] = now, th.packets
            f = th.latest_frame or {}
            hands = "+".join(h for h in ("left", "right") if h in f) or "none"
            st["status"] = f"{fps:.0f} pkt/s | {th.last_format} {th.last_size} B | hands: {hands}"
            if th.bad_packets:
                st["status"] += f" | bad: {th.bad_packets}"
                print(f"[QuestReceiver] bad packets: {th.bad_packets} (last error: {th.last_error})")
            try:
                scene = bpy.data.scenes.get(st.get("scene") or "") or bpy.context.scene
                cmp = compare_model(f, scene)
            except Exception as e:
                cmp = {}
                print(f"[QuestReceiver] compare_model: {e}")
            st["compare"] = {k: f"tracker vs model {v[0]:.1f}° ({v[1]}) | blender vs model {v[2]:.1f}° ({v[3]})"
                             for k, v in cmp.items()}
            for k, v in st["compare"].items():
                print(f"[QuestReceiver] {k}: {v}")
            ch = (f.get("right") or {}).get("chains", {})
            print(f"[QuestReceiver] {st['status']} | R idx {_flex_deg(ch.get('index', []), 1):+.0f}°")
            _tag_redraw()
        return 0.008

    return timer_callback


def find_hand_armatures(scene):
    t = get_targets(scene)
    return {s: t[s] for s in SIDES if t[s] is not None}


def is_running():
    th = _state().get("thread")
    return th is not None and th.is_alive()


def start_stream(scene=None):
    """Returns None on success or an error message."""
    scene = scene or bpy.context.scene
    stop_stream()
    hands = find_hand_armatures(scene)
    if not hands:
        return "Pick a Right Hand and/or Left Hand armature (the object must be in the scene)"
    if len(hands) == 2 and hands["Right"] == hands["Left"]:
        return "Right Hand and Left Hand are the same armature - pick two different ones"
    for side, obj in hands.items():
        if detect_bone_prefix(obj, side) is None:
            return f"{obj.name}: no *IndexProximal bone - not a hand rig"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("0.0.0.0", PORT))
    except OSError as e:
        sock.close()
        return f"UDP port {PORT} is busy ({e}). Close the other receiver."
    sock.settimeout(0.5)
    _calib.clear()
    _last_head_room["m"] = None
    _reset_hand_state()
    st0 = _state()
    st0["last_frame"] = None
    st0["compare"] = {}
    th = HandReceiverThread(sock, PORT)
    th.start()
    st = _state()
    st["thread"] = th
    st["scene"] = scene.name
    st["status"] = "Waiting for packets..."
    timer = _make_timer()
    st["timer"] = timer
    bpy.app.timers.register(timer, persistent=True)
    print(f"[QuestReceiver] START (UDP {PORT})")
    return None


def stop_stream():
    st = _state()
    timer = st.get("timer")
    if timer is not None and bpy.app.timers.is_registered(timer):
        bpy.app.timers.unregister(timer)
    st["timer"] = None
    th = st.get("thread")
    saved = None
    if th is not None and th.is_alive():
        th.kill()
        saved = _save_history(th)
    st["thread"] = None
    _reset_hand_state()
    st["status"] = f"Stopped | saved {os.path.basename(saved)}" if saved else "Stopped"
    # receiver from an old (non add-on) version of the script
    import builtins
    old = getattr(builtins, "_quest_receiver_thread", None)
    if old is not None and old.is_alive():
        old.running = False
        old.join(timeout=1.0)
    old_stop = getattr(builtins, "stop_stream", None)
    if old_stop is not None and old_stop is not stop_stream:
        try:
            old_stop()
        except Exception:
            pass
        try:
            del builtins.stop_stream
        except AttributeError:
            pass


def _save_history(th):
    """Writes the last ~HISTORY_SECONDS packets to <output_dir>/quest_last_frames.jsonl
    (1 line = {"t": receive_time, "frame": packet}). Overwritten on every Stop."""
    hist = list(th.history)
    if not hist:
        return None
    t_end = hist[-1][0]
    hist = [h for h in hist if t_end - h[0] <= HISTORY_SECONDS]
    folder = output_dir()
    path = os.path.join(folder, "quest_last_frames.jsonl")
    try:
        with open(path, "w", encoding="utf-8") as f:
            for t, raw in hist:
                f.write(json.dumps({"t": round(t, 4), "frame": raw}) + "\n")
        print(f"[QuestReceiver] Saved {len(hist)} packets ({HISTORY_SECONDS}s) to {path}")
        return path
    except OSError as e:
        print(f"[QuestReceiver] Could not save packet history: {e}")
        return None


def _m(m):
    return [[round(v, 6) for v in row] for row in m]


def _qv(q):
    return [round(q.w, 6), round(q.x, 6), round(q.y, 6), round(q.z, 6)]


def blender_state(scene):
    """Blender bone state (after the last applied frame)."""
    t = get_targets(scene)
    out = {}
    for side in SIDES:
        obj = t[side]
        if obj is None:
            continue
        cal = _calib.get((obj.name, side))
        bones = {}
        for pb in obj.pose.bones:
            b = pb.bone
            rest_local = (b.parent.matrix_local.inverted() @ b.matrix_local) if b.parent else b.matrix_local
            local_rot = (rest_local.to_3x3().normalized() @ pb.matrix_basis.to_3x3().normalized()).to_quaternion()
            bones[pb.name] = {
                "basis_quat_wxyz": _qv(pb.rotation_quaternion),
                "local_rot_wxyz": _qv(local_rot),               # relative to the parent bone (like pose_rotation in Godot)
                "rest_local_rot_wxyz": _qv(rest_local.to_quaternion()),
                "pose_head_armature": [round(v, 6) for v in pb.head],
                "pose_tail_armature": [round(v, 6) for v in pb.tail],
                "pose_rot_armature_wxyz": _qv(pb.matrix.to_quaternion()),
            }
        out[side] = {
            "object": obj.name,
            "mode": cal.mode if cal else None,
            "bone_prefix": cal.bone_prefix if cal else None,
            "native_score_deg": cal.native_score if cal else None,
            "matrix_world": _m(obj.matrix_world),
            "bones": bones,
        }
    return out


def save_debug_dump(scene=None):
    """Saves the last Quest frame + Blender bone state. Returns the path or None."""
    scene = scene or bpy.context.scene
    st = _state()
    frame = st.get("last_frame")
    if not frame:
        return None
    try:
        bpy.context.view_layer.update()     # make pb.matrix/head/tail current
    except Exception:
        pass
    data = {
        "saved": time.strftime("%Y-%m-%d %H:%M:%S"),
        "addon_version": list(bl_info["version"]),
        "rig_mode_setting": getattr(scene, "quest_rig_mode", None),
        "quest_frame": frame,
        "compare_model": {k: list(v) for k, v in compare_model(frame, scene).items()},
        "blender": blender_state(scene),
    }
    base = output_dir()
    folder = os.path.join(base, "quest_dumps")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, time.strftime("dump_%Y%m%d_%H%M%S.json"))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    print(f"[QuestReceiver] Debug dump: {path}")
    return path


def save_dump(filename="quest_custom_dump.json"):
    th = _state().get("thread")
    if not th or not th.latest_frame:
        print("[QuestReceiver] No frame to dump.")
        return
    path = os.path.join(output_dir(), filename)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(th.latest_frame, f, indent=2)
    print(f"[QuestReceiver] Saved: {path}")


# ----------------------------------------------------------------- UI
class QUESTHANDS_OT_toggle_stream(bpy.types.Operator):
    bl_idname = "questhands.toggle_stream"
    bl_label = "Start / Stop"
    bl_description = "Start or stop receiving Quest hand tracking (UDP). Stop also saves a debug dump"

    def execute(self, context):
        if is_running():
            stop_stream()
            path = None
            try:
                path = save_debug_dump(context.scene)
            except Exception as e:
                self.report({'WARNING'}, f"Could not save the debug dump: {e}")
            if path:
                _state()["last_dump"] = path
                self.report({'INFO'}, f"Quest Hands: stopped, dump: {path}")
            else:
                self.report({'INFO'}, "Quest Hands: stopped (no frames to save)")
        else:
            err = start_stream(context.scene)
            if err:
                self.report({'ERROR'}, err)
                return {'CANCELLED'}
            self.report({'INFO'}, f"Quest Hands: listening on port {PORT}")
        _tag_redraw()
        return {'FINISHED'}


class QUESTHANDS_OT_recenter(bpy.types.Operator):
    bl_idname = "questhands.recenter"
    bl_label = "Recenter"
    bl_description = ("Treat the current headset position as the origin: you stand above Head Origin "
                      "(or the world origin) looking along its +Y. The Quest app already recenters on start "
                      "and on the Meta-button recenter; use this only to correct it from Blender")

    reset: bpy.props.BoolProperty(default=False, options={'SKIP_SAVE'})

    def execute(self, context):
        sc = context.scene
        if self.reset:
            if "quest_recenter" in sc:
                del sc["quest_recenter"]
            self.report({'INFO'}, "Quest Hands: recenter cleared")
        else:
            H = _last_head_room["m"]
            if H is None:
                self.report({'ERROR'}, "No head data yet - press Start and put the headset on")
                return {'CANCELLED'}
            C = compute_recenter(H)
            sc["quest_recenter"] = [C[r][c] for r in range(4) for c in range(4)]
            self.report({'INFO'}, "Quest Hands: recentered on the current head position")
        _tag_redraw()
        return {'FINISHED'}


class QUESTHANDS_PT_panel(bpy.types.Panel):
    bl_label = "Quest Hands"
    bl_idname = "QUESTHANDS_PT_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Quest Hands"

    def draw(self, context):
        layout = self.layout
        running = is_running()
        row = layout.row()
        row.scale_y = 1.4
        if running:
            row.operator(QUESTHANDS_OT_toggle_stream.bl_idname, text="Stop", icon='PAUSE', depress=True)
        else:
            row.operator(QUESTHANDS_OT_toggle_stream.bl_idname, text="Start", icon='PLAY')
        layout.label(text=_state().get("status", ""), icon='CHECKMARK' if running else 'X')

        sc = context.scene
        col = layout.column(align=True)
        col.prop(sc, "quest_right_hand", text="Right Hand", icon='ARMATURE_DATA')
        col.prop(sc, "quest_left_hand", text="Left Hand", icon='ARMATURE_DATA')
        col.prop(sc, "quest_head", text="Head", icon='OBJECT_DATA')
        layout.prop(sc, "quest_rig_mode", expand=True)
        layout.label(text="Bone length:")
        layout.prop(sc, "quest_joint_positions", expand=True)
        layout.label(text="Inactive hand:")
        layout.prop(sc, "quest_lost_hand", expand=True)
        for side in SIDES:
            c = _calib.get((getattr(sc, "quest_right_hand" if side == "Right" else "quest_left_hand").name, side)) \
                if getattr(sc, "quest_right_hand" if side == "Right" else "quest_left_hand") else None
            if c is not None and c.ok:
                layout.label(text=f"{side}: {c.mode}", icon='BONE_DATA')

        box = layout.box()
        box.label(text="Reference points (empty = world origin)")
        box.prop(sc, "quest_head_origin", text="Head Origin", icon='EMPTY_AXIS')
        row = box.row(align=True)
        row.operator(QUESTHANDS_OT_recenter.bl_idname, text="Recenter", icon='PIVOT_CURSOR')
        r2 = row.row(align=True)
        r2.enabled = "quest_recenter" in sc
        op = r2.operator(QUESTHANDS_OT_recenter.bl_idname, text="", icon='X')
        op.reset = True
        box.prop(sc, "quest_hands_relative_to_head")
        sub = box.row()
        sub.enabled = not sc.quest_hands_relative_to_head
        sub.prop(sc, "quest_hands_origin", text="Hands Origin", icon='EMPTY_AXIS')
        t = get_targets(sc)
        for side in SIDES:
            obj = t[side]
            if obj is not None and detect_bone_prefix(obj, side) is None:
                layout.label(text=f"{obj.name}: no hand bones", icon='ERROR')
        if t["Head"] is not None:
            layout.label(text="Head: -Z = view direction, +Y = up", icon='INFO')
        cmpd = _state().get("compare") or {}
        if cmpd:
            box = layout.box()
            box.label(text="Compared to headset model (max):", icon='VIEWZOOM')
            for k, v in cmpd.items():
                box.label(text=f"{k}: {v}")
        last = _state().get("last_dump")
        if last and not running:
            layout.label(text=f"Dump: {os.path.basename(last)}", icon='FILE_TICK')
        layout.label(text=f"UDP port: {PORT}")


CLASSES = (QUESTHANDS_OT_toggle_stream, QUESTHANDS_OT_recenter, QUESTHANDS_PT_panel)


def _poll_armature(self, obj):
    return obj.type == 'ARMATURE'


def _poll_anchor(scene, obj):
    # an anchor cannot be an object we drive ourselves (loop)
    return obj not in {scene.quest_right_hand, scene.quest_left_hand, scene.quest_head}


def _on_target_change(self, context):
    _calib.clear()   # new armature -> new calibration


def _register_props():
    S = bpy.types.Scene
    S.quest_right_hand = bpy.props.PointerProperty(
        name="Right Hand", type=bpy.types.Object, poll=_poll_armature, update=_on_target_change,
        description="Right hand armature (bones Right*/...IndexProximal etc.)")
    S.quest_left_hand = bpy.props.PointerProperty(
        name="Left Hand", type=bpy.types.Object, poll=_poll_armature, update=_on_target_change,
        description="Left hand armature")
    S.quest_joint_positions = bpy.props.EnumProperty(
        name="Bone length", default="QUEST",
        items=[("QUEST", "From Quest", "Joint rotations + positions from the tracker (your real hand proportions, as in the headset)"),
               ("MODEL", "From model", "Rotations only; bone lengths and positions from the model (other character proportions)")])
    S.quest_lost_hand = bpy.props.EnumProperty(
        name="Inactive hand", default="HOLD",
        items=[("HOLD", "Hold", "Keep the last tracked pose"),
               ("HIDE", "Hide", "Hide the hand (armature + children) until tracking returns"),
               ("REST", "Rest", "Return the fingers to the rest pose (hand stays where it was)")])
    S.quest_rig_mode = bpy.props.EnumProperty(
        name="Rig", default="AUTO", update=_on_target_change,
        items=[("AUTO", "Auto", "Detect: Native when rig bone axes follow the Quest convention, otherwise Geometric"),
               ("NATIVE", "Native", "Quest rotations straight onto the bones (Godot / OpenXR rig, as in the headset)"),
               ("GEOMETRIC", "Geometric", "Calibration from rest pose geometry (any rig, bone axes do not matter)")])
    S.quest_head_origin = bpy.props.PointerProperty(
        name="Head Origin", type=bpy.types.Object, poll=_poll_anchor,
        description="Origin of the Quest space for the head (object location + rotation). Empty = world origin")
    S.quest_hands_relative_to_head = bpy.props.BoolProperty(
        name="Hands relative to Head", default=True,
        description="Hands are placed relative to the Head object (they follow it). Off = relative to Hands Origin")
    S.quest_hands_origin = bpy.props.PointerProperty(
        name="Hands Origin", type=bpy.types.Object, poll=_poll_anchor,
        description="Origin of the Quest space for the hands (object location + rotation). Empty = world origin")
    S.quest_head = bpy.props.PointerProperty(
        name="Head", type=bpy.types.Object,
        description="Any object (Empty, Camera...) - gets headset position and rotation; object -Z = view direction")


def _unregister_props():
    for name in ("quest_right_hand", "quest_left_hand", "quest_head", "quest_rig_mode", "quest_joint_positions",
                 "quest_lost_hand",
                 "quest_head_origin", "quest_hands_origin", "quest_hands_relative_to_head"):
        if hasattr(bpy.types.Scene, name):
            delattr(bpy.types.Scene, name)


def register():
    # safe re-run: unregister whatever is already registered
    for cls in reversed(CLASSES):
        old = getattr(bpy.types, cls.__name__, None)
        if old is not None:
            try:
                bpy.utils.unregister_class(old)
            except RuntimeError:
                pass
    for cls in CLASSES:
        bpy.utils.register_class(cls)
    _register_props()


def unregister():
    stop_stream()
    _unregister_props()
    for cls in reversed(CLASSES):
        old = getattr(bpy.types, cls.__name__, None)
        if old is not None:
            try:
                bpy.utils.unregister_class(old)
            except RuntimeError:
                pass


if __name__ == "__main__":
    # run from the Text Editor: stop the previous instance and re-register
    stop_stream()
    register()
