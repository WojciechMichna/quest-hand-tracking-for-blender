# Quest 3 Hand Tracking → Blender (live)

Real-time hand, head and body tracking from a **Meta Quest 3** streamed over Wi-Fi into **Blender**, where it drives hand armatures and a full humanoid character (Godot humanoid or Mixamo bone names).

- **Quest side:** a small Godot 4.7 OpenXR app (`hand_streamer.gd`) reads `XRHandTracker` and Meta body tracking (`XRBodyTracker`) every frame and sends them over UDP. Optional in-headset full-body avatar, a mirror and record buttons.
- **PC side:** a Blender add-on, *Oculus Quest Hand Tracking* (`blender_addon/blender_hand_receiver.py`), receives the packets on a background thread and poses the bones on the main thread.
- **Retarget helpers:** scripts in `blender_scripts/` connect the tracked hands to a Mixamo character (fingers, wrist, arm IK with elbow pole, thumbs).

> Polish documentation with more internals: [README.pl.md](README.pl.md)

```
[ Meta Quest 3 – Godot 4.7 OpenXR app ]
        │  UDP :5005: QHND v1 hands+head (~1.4 KB) + QBDY v1 body (636 B) per frame, 60–90 Hz
        │            QCTL v1 control (record start/stop)
        ▼
[ Blender 4.x / 5.x – "Quest Hands" add-on ]
        ├── receiver thread (socket, decode)
        └── bpy.app.timers (main thread) → pose bones of the hand armatures
                └── constraints → your character (Mixamo, custom rig …)
```


https://github.com/user-attachments/assets/4041eba9-8743-418c-8f3a-bcb3abac1399



## Features
- 24 joints per hand (wrist + 4 thumb + 5×4 fingers incl. metacarpals) plus head pose.
- Meta body tracking: 22 body joints (hips, spine, neck, head, shoulders, arms, legs, toes). Upper body is tracked by the headset cameras, legs are Meta's *Generative Legs* (estimated) – the packet marks which joints are really tracked.
- Blender **Body** field: drives a whole humanoid rig – bones named like Godot's humanoid profile (`Hips`, `LeftUpperArm`…) or **Mixamo** (`mixamorig:Hips`…, T-pose; bone axes are corrected automatically). Fingers come from hand tracking.
- In the headset (menu toggles, saved): **AVATAR** – see yourself as a full-body avatar instead of the yellow hands; **MIRROR** – a mirror 1 m to your left. Two **Record Start / Stop** touch buttons in front of you send a control packet to Blender.
- Compact binary protocol (one UDP datagram for both hands); legacy JSON still accepted.
- Works with one hand, two hands or none: inactive hand **Hold / Hide / Rest**.
- Rig modes: **Native** (bone axes match the data) or **Geometric** (any rig, axes computed from bone directions), **Auto** picks one.
- Bone length **From Quest** (uses the measured joint positions – your real hand size) or **From model** (keeps the model proportions).
- Reference empties: Head Origin (floor point of the Quest play space), hands relative to the head or to their own origin.
- Start / Stop from the side panel; Stop really ends the socket thread and dumps the last frames to JSON for debugging.
- Safe to reload the add-on while streaming (state kept in `bpy.app.driver_namespace`).

## Quick install (prebuilt release)
Download from the [Releases](../../releases) page: `quest-hand-tracking-for-blender.apk` and `OculusQuestHandTracking_<ver>.zip`.
Hand models: [`blender_models/BothHands.blend`](blender_models/BothHands.blend) from this repo (*Download raw file*).

1. **Quest app** – headset in *Developer Mode* (Meta Horizon phone app → Devices → Developer Mode), USB cable to the PC, then either drag the APK onto **SideQuest**, or run `adb install -r quest-hand-tracking-for-blender.apk`.
   The app shows up in *Library → Unknown Sources* as **Quest Hand Tracking**.
2. **Blender add-on** – *Edit → Preferences → Add-ons → ⌄ → Install from Disk…* → pick the `.zip` → enable *Oculus Quest Hand Tracking*.
3. Open `BothHands.blend`, press **N** in the 3D Viewport → **Quest Hands** tab → set *Right Hand* / *Left Hand* to the two hand armatures → **Start**.
   Windows Firewall asks about Blender the first time – allow it on *Private* networks (UDP 5005).
4. Find your PC IP (`ipconfig` → IPv4 address, e.g. `192.168.1.20`). PC and Quest must be on the same Wi-Fi/LAN.
5. Start the app on the Quest and put the controllers down – it uses hand tracking.
   On the floating keypad type the PC IP (touch a key with the index finger or point and pinch), then stand where the character should stand, look straight ahead and tap **START NOW**. That spot becomes the origin (holding the Meta button later re-centers it). The IP is remembered for next time.
6. Move your hands – the Blender hands follow live. **Stop** in the panel ends the stream.

No movement? Check: same network, firewall, correct IP, the panel status shows `pkt/s` instead of `Waiting for packets...`, hand tracking enabled on the Quest (Settings → Movement Tracking → Hand Tracking).

## Building from source
### Requirements
- Godot **4.7** with Android export templates, Android SDK + JDK set in *Editor Settings → Export → Android*.
- **Godot OpenXR Vendors** plugin **5.1.0** (5.2.0-rc1 broke hand + body tracking start here) from the Asset Library → `addons/godotopenxrvendors/` (not committed in this repo), then *Project → Install Android Build Template*.
- Blender **4.2+** (developed on 5.2); Python 3 and git for `make_release.py`.

### Run from the editor
Connect the Quest via USB, open the project in Godot and use *One-click deploy* (Android icon, top right). Blender: open `blender_addon/blender_hand_receiver.py` in the Text Editor → *Run Script* (no install needed).

### Making a release
**Blender add-on zip** – version comes from the git tag:
```
git tag v1.7.0
python make_release.py            # -> releases/OculusQuestHandTracking_v1.7.0.zip
python make_release.py --strict   # refuse if there are uncommitted changes or HEAD is not on a tag
```
**Quest APK** – in Godot: *Project → Export… → Android → Export Project* → save as `releases/quest-hand-tracking-for-blender.apk`.
With *Export With Debug* ticked it is signed with Godot's debug keystore (fine for sideloading); unticked needs a release keystore in the preset.
Keep `version/name` in `export_presets.cfg` equal to the tag.

Upload both files to a GitHub release for the tag.

## Add-on panel (Quest Hands tab)
| Setting | Meaning |
|---|---|
| Start / Stop | Opens / closes the UDP socket thread. Stop also writes `quest_dumps/dump_*.json` and `quest_last_frames.jsonl` next to the saved .blend (or `~/QuestHandTracking`). |
| Right Hand / Left Hand | Hand armatures to drive. |
| Head | Object that gets the headset position and rotation (–Z = view direction, +Y = up). |
| Body | Humanoid armature driven by body tracking: Godot humanoid names (axes = tracker axes) or Mixamo names in T-pose (axes corrected per bone). Hips get position + rotation, other bones rotation only (model proportions), the neck keeps its rest pose, fingers follow the hand tracker. Start works with only a Body set. |
| Rig | Auto / Native / Geometric. |
| Bone length | From Quest / From model. |
| Inactive hand | Hold (last pose) / Hide / Rest pose. |
| Head Origin, Hands Origin | Empties that place the Quest space in the scene; empty = world origin. You stand on Head Origin looking along its +Y (rotate it 180° on Z for a character facing −Y, e.g. Mixamo). |
| Recenter / X | Optional correction from Blender: the current head position becomes the origin. The Quest app already recenters on START and on the Meta-button recenter. X clears it. |

## In the headset
The start menu (keypad for the PC IP) has four buttons: **RESET IP**, **AVATAR on/off**, **MIRROR on/off**, **START NOW**. Avatar and mirror are off by default and remembered.

- **AVATAR**: a blue, 30 % transparent humanoid (`assets/avatar/Avatar.glb`, 1.78 m, Mixamo rig) driven by `XRBodyModifier3D`; replaces the yellow hands while body tracking has data. Its head is hidden (you are inside it). `body_rest_lengths.gd` keeps the spine/neck/head at the model's proportions (Meta's neck joint points forward to the middle of the head) while shoulders, arms and hands stay exactly on yours.
- **MIRROR**: placed once, 1 m to your left when you press START.
- **Record Start / Stop**: two buttons in front of you, a bit above the eyes. Touch one with an index fingertip to toggle; after a touch they are locked for 5 s (no double triggers). Each toggle sends a `QCTL` packet; the Blender add-on prints it to the system console (*Window → Toggle System Console*) – recording itself is the next step.

Legs bent while you stand? Meta fits the generated legs to the floor height of your Guardian – redraw the boundary / set the floor in the headset settings.

## Data convention
Joint rotations come from Godot's `XRHandTracker` (Godot skeleton convention, not raw OpenXR):
**+Y along the bone, +Z palm side, +X = Y×Z, finger flexion = rotation about +X.**
Each joint sends its rotation relative to its parent (`parent⁻¹ · joint`) and its position in the parent frame. Godot → Blender axes: `x → x, y → z, z → −y`.

## Binary packet – QHND v1 (little-endian)
| Block | Content | Size |
|---|---|---|
| header | `"QHND"`, u8 version = 1, u8 flags, u16 joint count = 24, u32 time ms | 12 B |
| head (flag bit0) | pos xyz, rot xyzw (f32) | 28 B |
| left hand (bit1), then right (bit2) | u32 joint validity mask, wrist pos + rot (7×f32), 24 × (rot xyzw, pos xyz) | 704 B |
| `model_rot` (bit3, debug only) | 24 × rot xyzw per present hand | 384 B / hand |

Both hands without debug: **1448 B**. A missing hand = no block. Unknown version or garbage → packet dropped and counted as *bad* in the panel.

## Binary packet – QBDY v1 (body, separate datagram)
| Block | Content | Size |
|---|---|---|
| header | `"QBDY"`, u8 version = 1, u8 flags (bit0 legs available, bit1 high-fidelity tracking), u16 joint count = 22, u32 time ms | 12 B |
| masks | u32 valid, u32 tracked (valid but not tracked = generated, e.g. legs) | 8 B |
| joints | 22 × (rot xyzw, pos xyz) f32, room space after recenter, Godot humanoid bone axes | 616 B |

Joint order: Hips, Spine, Chest, UpperChest, Neck, Head, Left/Right Shoulder, UpperArm, LowerArm, Hand (left first), Left/Right UpperLeg, LowerLeg, Foot, Toes.

## Binary packet – QCTL v1 (control)
`"QCTL"`, u8 version = 1, u8 command (1 = record start, 2 = record stop), u16 reserved, u32 time ms, u32 sequence – 16 B, sent 3× with the same sequence (the receiver drops repeats).

## Driving a Mixamo character
**Easiest (body tracking):** put the Mixamo character in T-pose as rest pose, set it as **Body**, rotate Head Origin 180° on Z. `rest_models.blend` is a ready example (Body = Armature, Head Origin = QuestOrigin).

**Hands only (constraints):** scripts in `blender_scripts/` (open in the Scripting workspace, edit the settings at the top, *Run Script*). All constraints they create are named `QH …`, so re-running is safe.

| Script | What it does |
|---|---|
| `mixamo_arm_setup.py` | One side per run (`SIDE = "Left"/"Right"`): finger Copy Rotation (Local→Local), hand Copy Rotation (World→World), IK on the forearm (chain 2) targeting the tracked wrist, elbow pole empty with the pole angle found automatically. |
| `mixamo_thumb_fix.py` | Re-rolls the Mixamo thumb bones so their axes match the tracked thumb, then adds the thumb constraints. |
| `mixamo_finger_constraints.py` | Fingers only (simpler, older variant). |

Notes: clear the arm pose rotations (Alt+R) before running; IK with a pole needs a slightly bent elbow (Mixamo rest pose is fine). For the head, parent an empty with the eye-to-neck offset under the *Head* object and use it as a Copy Rotation / IK target for `mixamorig:Head`.

The Mixamo character itself is **not** included (Mixamo license) – download your own from mixamo.com.

## Repository layout
| Path | Content |
|---|---|
| `blender_addon/blender_hand_receiver.py` | Blender add-on |
| `blender_scripts/` | Mixamo retarget helpers |
| `make_release.py` | Builds the installable add-on zip, version taken from the git tag |
| `hand_streamer.gd`, `vr_main.gd`, `menu.gd`, `*.tscn`, `project.godot` | Godot Quest app (streamer incl. body + control packets, XR setup, avatar, mirror, in-VR menu) |
| `record_buttons.gd` | Record Start/Stop touch buttons |
| `body_rest_lengths.gd` | Skeleton modifier: avatar spine/neck/head proportions |
| `assets/avatar/` | Full-body avatar (glb + Godot import with Mixamo→humanoid bone map) |
| `tools/export_body_for_blender.gd` | Godot EditorScript: exports the avatar with Godot humanoid bone names/axes to `blender_models/BodyHumanoid.glb` |
| `rest_models.blend` | Blender scene: the avatar (Mixamo rig, T-pose) set up as Body |
| `assets/hands/` | Hand models used in the Godot app (glTF) |
| `blender_models/` | Blender scenes with the rigged tracking hands |
| `packet_recorder.py` | Records incoming UDP packets to files (no Blender needed) |
| `export_hands_for_blender.py` | Rebuilds `blender_models/*.blend` from `assets/hands/*.gltf` (`blender -b -P …`) |
| `quest_dump.json` | Sample frame for testing without a headset |

## Roadmap
- Recording to keyframes (driven by the Record buttons), offline smoothing.
- Mirror without negative scale (pose copy with left/right swap).
- Retarget to non-human rigs (dragon paw).

## License
MIT – see [LICENSE](LICENSE). Third-party: Godot OpenXR Vendors plugin (MIT, with Meta/Khronos SDK licenses), not bundled. Mixamo assets are not included.
