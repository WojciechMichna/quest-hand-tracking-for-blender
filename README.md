# Quest 3 Hand Tracking → Blender (live)

Real-time hand and head tracking from a **Meta Quest 3** streamed over Wi-Fi into **Blender**, where it drives hand armatures – and, through constraints, a full character rig (tested with Mixamo).

- **Quest side:** a small Godot 4.7 OpenXR app (`hand_streamer.gd`) reads `XRHandTracker` joints every frame and sends them over UDP.
- **PC side:** a Blender add-on, *Oculus Quest Hand Tracking* (`blender_addon/blender_hand_receiver.py`), receives the packets on a background thread and poses the bones on the main thread.
- **Retarget helpers:** scripts in `blender_scripts/` connect the tracked hands to a Mixamo character (fingers, wrist, arm IK with elbow pole, thumbs).

> Polish documentation with more internals: [README.pl.md](README.pl.md)

```
[ Meta Quest 3 – Godot 4.7 OpenXR app ]
        │  UDP :5005, binary QHND v1 (~1.4 KB/frame, 60–90 Hz)
        ▼
[ Blender 4.x / 5.x – "Quest Hands" add-on ]
        ├── receiver thread (socket, decode)
        └── bpy.app.timers (main thread) → pose bones of the hand armatures
                └── constraints → your character (Mixamo, custom rig …)
```


https://github.com/user-attachments/assets/4041eba9-8743-418c-8f3a-bcb3abac1399



## Features
- 24 joints per hand (wrist + 4 thumb + 5×4 fingers incl. metacarpals) plus head pose.
- Compact binary protocol (one UDP datagram for both hands); legacy JSON still accepted.
- Works with one hand, two hands or none: inactive hand **Hold / Hide / Rest**.
- Rig modes: **Native** (bone axes match the data) or **Geometric** (any rig, axes computed from bone directions), **Auto** picks one.
- Bone length **From Quest** (uses the measured joint positions – your real hand size) or **From model** (keeps the model proportions).
- Reference empties: Head Origin (floor point of the Quest play space), hands relative to the head or to their own origin.
- Start / Stop from the side panel; Stop really ends the socket thread and dumps the last frames to JSON for debugging.
- Safe to reload the add-on while streaming (state kept in `bpy.app.driver_namespace`).

## Quick install (prebuilt release)
Download from the [Releases](../../releases) page:
`QuestHandTracking_<ver>.apk`, `OculusQuestHandTracking_<ver>.zip`, `QuestHandTracking_<ver>_hands.blend`.

1. **Quest app** – headset in *Developer Mode* (Meta Horizon phone app → Devices → Developer Mode), USB cable to the PC, then either drag the APK onto **SideQuest**, or run `adb install -r QuestHandTracking_<ver>.apk`.
   The app shows up in *Library → Unknown Sources* as **Quest Hand Tracking**.
2. **Blender add-on** – *Edit → Preferences → Add-ons → ⌄ → Install from Disk…* → pick the `.zip` → enable *Oculus Quest Hand Tracking*.
3. Open `QuestHandTracking_<ver>_hands.blend`, press **N** in the 3D Viewport → **Quest Hands** tab → set *Right Hand* / *Left Hand* to the two hand armatures → **Start**.
   Windows Firewall asks about Blender the first time – allow it on *Private* networks (UDP 5005).
4. Find your PC IP (`ipconfig` → IPv4 address, e.g. `192.168.1.20`). PC and Quest must be on the same Wi-Fi/LAN.
5. Start the app on the Quest and put the controllers down – it uses hand tracking.
   On the floating keypad type the PC IP (touch a key with the index finger or point and pinch), then **START NOW** (or wait for the 30 s countdown). The IP is remembered for next time.
6. Move your hands – the Blender hands follow live. **Stop** in the panel ends the stream.

No movement? Check: same network, firewall, correct IP, the panel status shows `pkt/s` instead of `Waiting for packets...`, hand tracking enabled on the Quest (Settings → Movement Tracking → Hand Tracking).

## Building from source
### Requirements
- Godot **4.7** with Android export templates, Android SDK + JDK set in *Editor Settings → Export → Android*.
- **Godot OpenXR Vendors** plugin **5.1.0** from the Asset Library → `addons/godotopenxrvendors/` (not committed in this repo), then *Project → Install Android Build Template*.
- Blender **4.2+** (developed on 5.2); Python 3 and git for `make_release.py`.

### Run from the editor
Connect the Quest via USB, open the project in Godot and use *One-click deploy* (Android icon, top right). Blender: open `blender_addon/blender_hand_receiver.py` in the Text Editor → *Run Script* (no install needed).

### Making a release
```
git tag v1.7.0                       # the version comes from the tag
python make_release.py --apk --godot "C:/path/Godot_v4.7-stable_win64.exe"
```
Output in `releases/`:

| File | What |
|---|---|
| `OculusQuestHandTracking_v1.7.0.zip` | Blender add-on, `bl_info` version set from the tag |
| `QuestHandTracking_v1.7.0_hands.blend` | copy of `blender_models/BothHands.blend` |
| `QuestHandTracking_v1.7.0.apk` | Quest app, preset *Android*, debug-signed (`--apk-release` for a release keystore) |

Without `--apk` only the add-on and the .blend are built. `--strict` refuses to build from uncommitted changes or an untagged commit.
The APK can also be exported by hand: *Project → Export… → Android → Export Project*.
Keep `version/name` in `export_presets.cfg` equal to the tag – the script warns otherwise.

## Add-on panel (Quest Hands tab)
| Setting | Meaning |
|---|---|
| Start / Stop | Opens / closes the UDP socket thread. Stop also writes `quest_dumps/dump_*.json` and `quest_last_frames.jsonl` next to the saved .blend (or `~/QuestHandTracking`). |
| Right Hand / Left Hand | Hand armatures to drive. |
| Head | Object that gets the headset position and rotation (–Z = view direction, +Y = up). |
| Rig | Auto / Native / Geometric. |
| Bone length | From Quest / From model. |
| Inactive hand | Hold (last pose) / Hide / Rest pose. |
| Head Origin, Hands Origin | Empties that place the Quest space in the scene; empty = world origin. |

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

## Driving a Mixamo character
Scripts in `blender_scripts/` (open in the Scripting workspace, edit the settings at the top, *Run Script*). All constraints they create are named `QH …`, so re-running is safe.

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
| `hand_streamer.gd`, `vr_main.gd`, `menu.gd`, `*.tscn`, `project.godot` | Godot Quest app (streamer, XR setup, in-VR IP keypad) |
| `assets/hands/` | Hand models used in the Godot app (glTF) |
| `blender_models/` | Blender scenes with the rigged tracking hands |
| `packet_recorder.py` | Records incoming UDP packets to files (no Blender needed) |
| `export_hands_for_blender.py` | Rebuilds `blender_models/*.blend` from `assets/hands/*.gltf` (`blender -b -P …`) |
| `quest_dump.json` | Sample frame for testing without a headset |

## Roadmap
- Recording to keyframes / baking IK targets, offline smoothing.
- Full-body IK from head + hands (VRChat-style).
- Retarget to non-human rigs (dragon paw).

## License
MIT – see [LICENSE](LICENSE). Third-party: Godot OpenXR Vendors plugin (MIT, with Meta/Khronos SDK licenses), not bundled. Mixamo assets are not included.
