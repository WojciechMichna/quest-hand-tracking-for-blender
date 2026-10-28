# Quest Body and Hands Tracking → Blender (live)

Real-time hand, head and full-body tracking from a **Meta Quest 3** streamed over Wi-Fi into **Blender**, where it drives hand armatures and a full humanoid character (Godot humanoid or Mixamo bone names). Standalone headset only: no PC VR, no Quest Link, no suit or markers. Takes are recorded from the headset and baked into Blender actions.

- **Quest side:** a small Godot 4.7 OpenXR app (`hand_streamer.gd`) reads `XRHandTracker` and Meta body tracking (`XRBodyTracker`) every frame and sends them over UDP. Optional in-headset full-body avatar, a mirror and record buttons.
- **PC side:** a Blender add-on, *Quest Body and Hands Tracking* (`blender_addon/blender_hand_receiver.py`), receives the packets on a background thread, poses the bones on the main thread, records takes and bakes them into actions.
- **Retarget helpers:** scripts in `blender_scripts/` connect the tracked hands to a Mixamo character (fingers, wrist, arm IK with elbow pole, thumbs).

> Polish documentation with more internals: [README.pl.md](README.pl.md)

```
[ Meta Quest 3 – Godot 4.7 OpenXR app ]
        │  UDP :5005: QHND v1 hands+head (~1.4 KB) + QBDY v1 body (636 B) per frame, 60–90 Hz
        │            QCTL v1 control (record start/stop)
        ▼
[ Blender 4.x / 5.x – "Quest Body and Hands Tracking" add-on ]
        ├── receiver thread (socket, decode, record takes → quest_takes/*.qrec)
        ├── bpy.app.timers (main thread) → pose bones: Body rig, hand armatures, Head object
        │       └── (optional) constraints → your character (custom rig …)
        └── Bake Take → action "Take_…" (scene fps, optional smoothing)
```

### Body tracking, mirror and recording (v1.9)

[![Body tracking, mirror and recording](https://img.youtube.com/vi/s0vs6Ofavbo/maxresdefault.jpg)](https://youtu.be/s0vs6Ofavbo)

### Hand tracking (v1.8)

https://github.com/user-attachments/assets/4041eba9-8743-418c-8f3a-bcb3abac1399



## Features
- 24 joints per hand (wrist + 4 thumb + 5×4 fingers incl. metacarpals) plus head pose.
- Meta body tracking: 22 body joints (hips, spine, neck, head, shoulders, arms, legs, toes). Upper body is tracked by the headset cameras, legs are Meta's *Generative Legs* (estimated) – the packet marks which joints are really tracked.
- Blender **Body** field: drives a whole humanoid rig – bones named like Godot's humanoid profile (`Hips`, `LeftUpperArm`…) or **Mixamo** (`mixamorig:Hips`…, T-pose; bone axes are corrected automatically). Fingers come from hand tracking.
- In the headset (menu toggles, saved): **AVATAR** – see yourself as a full-body avatar instead of the yellow hands; **MIRROR** – a mirror 1 m to your left. Two **Record Start / Stop** touch buttons in front of you record takes in Blender (3 s countdown to get into the pose).
- **Recording takes**: Record buttons in the headset (3 s countdown) or in the panel; raw packets saved to `quest_takes/`, baked into a new action at the scene frame rate, optional zero-phase smoothing, re-bake any take later. See *Recording takes*.
- **Prepare Mixamo Body**: one click makes an imported Mixamo FBX ready for the Body field (T-pose as rest, importer rotation/scale applied, optional height). **Straighten head** fixes a head pushed forward by the rig.
- Compact binary protocol (one UDP datagram for both hands). The headset builds the packets straight into packed float arrays in the wire layout (about 90 µs per frame on desktop CPU for hands + body, 3.5× less than before), a worker thread sends them. The add-on still accepts the old JSON packets.
- Works with one hand, two hands or none: inactive hand **Hold / Hide / Rest**.
- Rig modes: **Native** (bone axes match the data) or **Geometric** (any rig, axes computed from bone directions), **Auto** picks one.
- Bone length **From Quest** (uses the measured joint positions – your real hand size) or **From model** (keeps the model proportions).
- Reference empties: Head Origin (floor point of the Quest play space), hands relative to the head or to their own origin.
- Start / Stop from the side panel; Stop really ends the socket thread and dumps the last frames to JSON for debugging.
- Safe to reload the add-on while streaming (state kept in `bpy.app.driver_namespace`).

## Quick install (prebuilt release)
Download from the [Releases](../../releases) page: `quest-body-and-hands-tracking.apk` (up to v1.8: `quest-hand-tracking-for-blender.apk`) and `QuestBodyAndHandsTracking_<ver>.zip` (up to v1.8: `OculusQuestHandTracking_<ver>.zip`).
Hand models: [`blender_models/BothHands.blend`](blender_models/BothHands.blend) from this repo (*Download raw file*).

1. **Quest app** – headset in *Developer Mode* (Meta Horizon phone app → Devices → Developer Mode), USB cable to the PC, then either drag the APK onto **SideQuest**, or run `adb install -r quest-body-and-hands-tracking.apk` (installs over the old version, same package id).
   The app shows up in *Library → Unknown Sources* as **Quest Hand Tracking**.
2. **Blender add-on** – *Edit → Preferences → Add-ons → ⌄ → Install from Disk…* → pick the `.zip` → enable *Quest Body and Hands Tracking*. Upgrading from v1.8 or older (*Oculus Quest Hand Tracking*): remove that add-on first, the package was renamed and both cannot be enabled together. Scene settings are kept.
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
python make_release.py            # -> releases/QuestBodyAndHandsTracking_v1.9.0.zip
python make_release.py --strict   # refuse if there are uncommitted changes or HEAD is not on a tag
```
**Quest APK** – in Godot: *Project → Export… → Android → Export Project* → save as `releases/quest-body-and-hands-tracking.apk`.
With *Export With Debug* ticked it is signed with Godot's debug keystore (fine for sideloading); unticked needs a release keystore in the preset.
Keep `version/name` in `export_presets.cfg` equal to the tag.

Upload both files to a GitHub release for the tag.

## Add-on panel (Quest Hands tab)
| Setting | Meaning |
|---|---|
| Start / Stop | Opens / closes the UDP socket thread. Stop also writes `quest_dumps/dump_*.json` and `quest_last_frames.jsonl` next to the saved .blend (or `~/QuestHandTracking`). |
| Right Hand / Left Hand | Hand armatures to drive. |
| Head | Object that gets the headset position and rotation (–Z = view direction, +Y = up). |
| Body | Humanoid armature driven by body tracking: Godot humanoid names (axes = tracker axes) or Mixamo names in T-pose (axes corrected per bone). Hips get position + rotation, other bones rotation only (model proportions), the neck keeps its rest pose, fingers follow the hand tracker. Start works with only a Body set. **Straighten head** (0–1, default 1) moves the head bone onto the end of the neck: auto-rigs often place the head joint a few cm in front of it, which looks like a head pushed forward. **Prepare Mixamo Body** – see below. |
| Rig | Auto / Native / Geometric. |
| Bone length | From Quest / From model. |
| Inactive hand | Hold (last pose) / Hide / Rest pose. |
| Head Origin, Hands Origin | Empties that place the Quest space in the scene; empty = world origin. You stand on Head Origin looking along its +Y (rotate it 180° on Z for a character facing −Y, e.g. Mixamo). |
| Recenter / X | Optional correction from Blender: the current head position becomes the origin. The Quest app already recenters on START and on the Meta-button recenter. X clears it. |

## In the headset
The start menu (keypad for the PC IP) has four buttons: **RESET IP**, **AVATAR on/off**, **MIRROR on/off**, **START NOW**. Avatar and mirror are off by default and remembered.

- **AVATAR**: a blue, 30 % transparent humanoid (`assets/avatar/Avatar.glb`, 1.78 m, Mixamo rig) driven by `XRBodyModifier3D`; replaces the yellow hands while body tracking has data. Its head is hidden (you are inside it). `body_rest_lengths.gd` keeps the spine/neck/head at the model's proportions (Meta's neck joint points forward to the middle of the head) while shoulders, arms and hands stay exactly on yours.
- **MIRROR**: placed once, 1 m to your left when you press START.
- **Record Start / Stop**: two buttons in front of you, a bit above the eyes. Touch one with an index fingertip to toggle; after a touch they are locked for 5 s (no double triggers). Start shows a 3 s countdown in front of your eyes (time to get into the pose), then sends `QCTL` record start and shows `REC m:ss` until you touch Stop. See *Recording takes*.

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

## Take file – .qrec v1
`"QREC"`, u8 version = 1, 3 × pad, f64 start (unix time); then per datagram: f64 receive time, u16 length, the QHND/QBDY datagram as received.

## Recording takes
1. Press **Start** in the add-on, put the headset on, touch **Record Start** (or press **Record** in the panel – no countdown).
2. Perform; touch **Record Stop**.
3. The add-on writes the raw packets to `quest_takes/take_YYYYMMDD_HHMMSS.qrec` next to the .blend and, with **Auto bake** on, bakes it right away into a new action `Take_…` on the Body, the hand armatures and the Head object (one action, a slot per object). The previous action stays in the file (fake user).

How the bake works: packets are timed by the Quest clock (not by Wi-Fi arrival), every packet is applied with the same code as the live preview, and the resulting bone/object channels are resampled to the scene frame rate from the start frame (linear keys, quaternion sign kept continuous); the frame range is set to the take. Bones the tracking never touched stay unanimated. Optional zero-phase low-pass smoothing: **Smooth body** / **Fingers** in Hz (0 = raw; try 6 and 8–10). The raw take is kept, so you can re-bake it with other settings or onto another rig: **Bake file…** or the *Bake take_…* buttons for the last takes. While the timeline plays, the live stream does not override the pose.

**Filters.** Live preview (*Live filter*, on by default, the takes are still recorded raw): a spike gate holds back a joint that jumps faster than a human can move until 3 samples agree on the new place (a hand found again 25 cm away is real and passes), then a One Euro filter removes jitter when you hold still and adds almost no lag on fast moves (*Smoothing* = min cutoff in Hz, *Speed* = beta). Bake: *Remove spikes* (on by default) runs a Hampel filter on the raw samples before resampling: a joint farther than 3 robust sigmas from the median of ±60 ms is replaced by the median, so 1 to 3 sample glitches disappear while real moves and steps stay; then the optional Butterworth smoothing.

A take is closed automatically after 2 s without packets (headset off, app closed) or after 10 min. Stop in the panel also closes a running take.

## Driving a Mixamo character
**Easiest (body tracking):** import the Mixamo FBX (downloaded *With Skin*, T-pose), select its armature and press **Prepare Mixamo Body** in the Quest Hands panel. In one step it bakes the T-pose from the action into the mesh and makes it the rest pose (removing the action), applies the importer's 90° rotation and 0.01 scale, optionally scales the character to a given height, checks the bone names and that the arms are horizontal, sets it as **Body** and creates a `QuestOrigin` empty rotated 180° on Z as Head Origin if none is set. Meshes with shape keys cannot have the pose baked in – untick *Current pose as rest* for them (the rest pose must then already be a T-pose).

`rest_models.blend` is a ready example (Body = Armature, Head Origin = QuestOrigin).

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
- Trimming takes, retarget of takes to non-human characters (dragon paw).
- Mirror without negative scale (pose copy with left/right swap).
- Retarget to non-human rigs (dragon paw).

## License
MIT – see [LICENSE](LICENSE). Third-party: Godot OpenXR Vendors plugin (MIT, with Meta/Khronos SDK licenses), not bundled. Mixamo assets are not included.
