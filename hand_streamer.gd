extends Node
class_name HandStreamer
## Streams head, wrist points, and finger bone chains (rotation + length) over UDP.
## Reads live OpenXR joint tracking directly from XRHandTracker for zero latency
## and complete independence from Skeleton3D modifier update order.

@export var enabled: bool = true
@export var target_ip: String = "192.168.0.223"
@export var target_port: int = 5005
@export var enable_broadcast: bool = false
## Binary packet format (QHND v1, ~1.45 KB for both hands, fits one UDP datagram/MTU).
## Off = legacy JSON (~5 KB). The Blender add-on accepts both.
@export var use_binary: bool = true

# --- Binary format QHND v1 (little-endian) -----------------------------------
# header (12 B): "QHND" | u8 version=1 | u8 flags | u16 joint_count | u32 time_ms
#   flags: bit0 head, bit1 left hand, bit2 right hand, bit3 model_rot blocks present
# head  (28 B): pos xyz f32, rot xyzw f32                       (only if bit0)
# hand  (for each present hand, left first, then right):
#   u32 valid_mask (bit i = joint i has valid orientation+position, joint order = FINGER_CHAINS)
#   wrist pos xyz f32, rot xyzw f32                               (28 B)
#   joint_count x (rot xyzw f32, pos xyz f32)                     (24 x 28 B)
#   if bit3: joint_count x model_rot xyzw f32                     (24 x 16 B)
const QHND_MAGIC := "QHND"
const QHND_VERSION := 1
var _JOINT_VALID_FLAGS: int = XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID

var xr_camera: XRCamera3D
var left_hand_node: XRNode3D
var right_hand_node: XRNode3D
var left_skeleton: Skeleton3D
var right_skeleton: Skeleton3D

# Finger chain definitions (OpenXR humanoid naming)
const FINGER_CHAINS := {
	"thumb": ["ThumbMetacarpal", "ThumbProximal", "ThumbDistal", "ThumbTip"],
	"index": ["IndexMetacarpal", "IndexProximal", "IndexIntermediate", "IndexDistal", "IndexTip"],
	"middle": ["MiddleMetacarpal", "MiddleProximal", "MiddleIntermediate", "MiddleDistal", "MiddleTip"],
	"ring": ["RingMetacarpal", "RingProximal", "RingIntermediate", "RingDistal", "RingTip"],
	"little": ["LittleMetacarpal", "LittleProximal", "LittleIntermediate", "LittleDistal", "LittleTip"]
}

# Mapping bone short names to OpenXR HandJoint enum
const JOINT_MAP := {
	"ThumbMetacarpal": XRHandTracker.HAND_JOINT_THUMB_METACARPAL,
	"ThumbProximal": XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL,
	"ThumbDistal": XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL,
	"ThumbTip": XRHandTracker.HAND_JOINT_THUMB_TIP,

	"IndexMetacarpal": XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
	"IndexProximal": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
	"IndexIntermediate": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
	"IndexDistal": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
	"IndexTip": XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,

	"MiddleMetacarpal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
	"MiddleProximal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
	"MiddleIntermediate": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
	"MiddleDistal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,
	"MiddleTip": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,

	"RingMetacarpal": XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
	"RingProximal": XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
	"RingIntermediate": XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
	"RingDistal": XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,
	"RingTip": XRHandTracker.HAND_JOINT_RING_FINGER_TIP,

	"LittleMetacarpal": XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
	"LittleProximal": XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
	"LittleIntermediate": XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
	"LittleDistal": XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
	"LittleTip": XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
}

# Parent relationship matching OpenXR hand skeleton hierarchy
const JOINT_PARENTS := {
	XRHandTracker.HAND_JOINT_THUMB_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_THUMB_METACARPAL,
	XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_THUMB_TIP: XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL,

	XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE: XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP: XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,

	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE: XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP: XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,

	XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE: XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_RING_FINGER_TIP: XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,

	XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL: XRHandTracker.HAND_JOINT_WRIST,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL: XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE: XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL: XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP: XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
}

# Thread synchronization: Producer -> Consumer (strictly latest frame, no queue)
var _mutex: Mutex = Mutex.new()
var _semaphore: Semaphore = Semaphore.new()
var _thread: Thread = Thread.new()
var _running: bool = false
var _latest_frame: Dictionary = {}
var _has_new_frame: bool = false

# DEBUG: headset model bone rotations (after XRHandModifier3D), for comparison in Blender.
# Set to false if packets get too large / too slow.
@export var send_model_bones: bool = false
var _model_rot := {"Left": {}, "Right": {}}    # prefix -> {short_name: Quaternion}
var _bone_idx := {"Left": {}, "Right": {}}     # prefix -> {short_name: bone index}

# --- Recenter -----------------------------------------------------------------
# Everything we send (head, wrists) is expressed relative to where the user stood and
# looked when streaming started: that spot = origin on the floor, view direction = -Z.
# Without it the origin is wherever the Quest put its floor origin (headset on the desk
# when the app was launched, a redrawn boundary...).
## Recenter automatically once the head is tracked after start, and on the system recenter (hold Meta button).
@export var auto_recenter: bool = true
var _center: Transform3D = Transform3D.IDENTITY
var _recenter_pending: bool = true
var _recenter_delay: float = 0.5     # seconds of valid head tracking before the first recenter


## Makes the current headset position (on the floor) + yaw the new origin of the sent data.
func recenter() -> void:
	if not xr_camera:
		return
	var ht: Transform3D = xr_camera.transform
	var f: Vector3 = -ht.basis.z
	f.y = 0.0
	if f.length_squared() < 1e-6:
		f = ht.basis.y        # looking straight down/up: use the head's up axis
		f.y = 0.0
	if f.length_squared() < 1e-6:
		return
	var origin := Vector3(ht.origin.x, 0.0, ht.origin.z)
	_center = Transform3D(Basis.looking_at(f.normalized(), Vector3.UP), origin).affine_inverse()
	_recenter_pending = false
	print("[HandStreamer] Recentered at ", origin)


func _on_pose_recentered() -> void:
	# The Quest moved its own origin; our stored offset is stale -> recenter on the next frame.
	_recenter_pending = true
	_recenter_delay = 0.0


func _ready() -> void:
	_load_config()

	# Locate XR nodes
	var origin: XROrigin3D = get_parent() if get_parent() is XROrigin3D else get_node_or_null("../XROrigin3D")
	if not origin:
		origin = get_tree().root.find_child("XROrigin3D", true, false)

	if origin:
		xr_camera = origin.find_child("XRCamera3D", true, false) as XRCamera3D
		left_hand_node = origin.find_child("LeftHand", true, false) as XRNode3D
		right_hand_node = origin.find_child("RightHand", true, false) as XRNode3D

	set_process(true)

	var xri := XRServer.find_interface("OpenXR")
	if xri and xri.has_signal("pose_recentered"):
		xri.connect("pose_recentered", _on_pose_recentered)

	if enabled:
		_running = true
		_thread.start(_consumer_thread_func)
		print("[HandStreamer] Consumer thread started. Target: %s:%d" % [target_ip, target_port])


func _load_config() -> void:
	var cfg_path := "user://stream_config.json"
	if FileAccess.file_exists(cfg_path):
		var file := FileAccess.open(cfg_path, FileAccess.READ)
		if file:
			var txt := file.get_as_text()
			var json = JSON.parse_string(txt)
			if json is Dictionary:
				if json.has("target_ip"):
					target_ip = str(json["target_ip"])
				if json.has("target_port"):
					target_port = int(json["target_port"])
				if json.has("enable_broadcast"):
					enable_broadcast = bool(json["enable_broadcast"])
				print("[HandStreamer] Config loaded from user://: ", target_ip, ":", target_port)
	else:
		var save_file := FileAccess.open(cfg_path, FileAccess.WRITE)
		if save_file:
			var default_cfg := {
				"target_ip": target_ip,
				"target_port": target_port,
				"enable_broadcast": enable_broadcast
			}
			save_file.store_string(JSON.stringify(default_cfg, "\t"))


func _cache_skeletons() -> void:
	if not left_skeleton and left_hand_node:
		left_skeleton = _find_skeleton(left_hand_node)
		if left_skeleton:
			print("[HandStreamer] Left skeleton found: %d bones" % left_skeleton.get_bone_count())
			_hook_skeleton(left_skeleton, "Left")

	if not right_skeleton and right_hand_node:
		right_skeleton = _find_skeleton(right_hand_node)
		if right_skeleton:
			print("[HandStreamer] Right skeleton found: %d bones" % right_skeleton.get_bone_count())
			_hook_skeleton(right_skeleton, "Right")


func _hook_skeleton(skel: Skeleton3D, prefix: String) -> void:
	var idx := {}
	for short in JOINT_MAP.keys():
		var b := skel.find_bone(prefix + short)
		if b != -1:
			idx[short] = b
	_bone_idx[prefix] = idx
	# The pose is final (after modifiers such as XRHandModifier3D) only in this signal.
	if skel.has_signal("skeleton_updated"):
		skel.skeleton_updated.connect(_on_skeleton_updated.bind(skel, prefix))
	print("[HandStreamer] %s model bones hooked: %d" % [prefix, idx.size()])


func _on_skeleton_updated(skel: Skeleton3D, prefix: String) -> void:
	if not send_model_bones:
		return
	var out := {}
	var idx: Dictionary = _bone_idx[prefix]
	for short in idx.keys():
		out[short] = skel.get_bone_pose_rotation(idx[short])
	_model_rot[prefix] = out


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null


# --- PRODUCER (Runs on Main VR Thread, ~90 FPS) ---
func _process(_delta: float) -> void:
	if not enabled or not _running:
		return

	if not left_skeleton or not right_skeleton:
		_cache_skeletons()

	if auto_recenter and _recenter_pending and xr_camera and xr_camera.transform != Transform3D.IDENTITY:
		_recenter_delay -= _delta
		if _recenter_delay <= 0.0:
			recenter()

	var frame := {
		"time": Time.get_ticks_msec(),
	}

	# 1. Head as point in room space
	if xr_camera:
		var ht: Transform3D = _center * xr_camera.transform
		var hq: Quaternion = ht.basis.get_rotation_quaternion()
		frame["head"] = {
			"pos": [snappedf(ht.origin.x, 0.0001), snappedf(ht.origin.y, 0.0001), snappedf(ht.origin.z, 0.0001)],
			"rot": [snappedf(hq.x, 0.0001), snappedf(hq.y, 0.0001), snappedf(hq.z, 0.0001), snappedf(hq.w, 0.0001)]
		}

	# 2. Left Hand
	var l_trk = XRServer.get_tracker(&"/user/hand_tracker/left")
	if l_trk:
		var l_tracked: bool = l_trk.has_tracking_data if "has_tracking_data" in l_trk else true
		if l_tracked:
			frame["left"] = _extract_hand(l_trk, "Left", left_hand_node, left_skeleton)
	elif left_skeleton and left_hand_node:
		frame["left"] = _extract_hand_fallback("Left", left_hand_node, left_skeleton)

	# 3. Right Hand
	var r_trk = XRServer.get_tracker(&"/user/hand_tracker/right")
	if r_trk:
		var r_tracked: bool = r_trk.has_tracking_data if "has_tracking_data" in r_trk else true
		if r_tracked:
			frame["right"] = _extract_hand(r_trk, "Right", right_hand_node, right_skeleton)
	elif right_skeleton and right_hand_node:
		frame["right"] = _extract_hand_fallback("Right", right_hand_node, right_skeleton)

	# Store into shared buffer (OVERWRITE previous unread frame - NO QUEUE)
	_mutex.lock()
	_latest_frame = frame
	_has_new_frame = true
	_mutex.unlock()

	_semaphore.post()


func _extract_hand(tracker: RefCounted, prefix: String, hand_node: XRNode3D, skeleton: Skeleton3D) -> Dictionary:
	var hand_data := {}

	# Cache joint transforms directly from OpenXR tracker
	var transforms: Dictionary = {}
	var inv_transforms: Dictionary = {}
	var joint_flags: Dictionary = {}

	if tracker is XRHandTracker:
		for joint in range(XRHandTracker.HAND_JOINT_MAX):
			var flags: int = tracker.get_hand_joint_flags(joint)
			joint_flags[joint] = flags
			# Even without flags check, get_hand_joint_transform returns the live transform
			var t: Transform3D = tracker.get_hand_joint_transform(joint)
			transforms[joint] = t
			inv_transforms[joint] = t.affine_inverse()

	# 1. Wrist root point in room space
	var wt: Transform3D = Transform3D.IDENTITY
	if transforms.has(XRHandTracker.HAND_JOINT_WRIST) and transforms[XRHandTracker.HAND_JOINT_WRIST] != Transform3D.IDENTITY:
		wt = transforms[XRHandTracker.HAND_JOINT_WRIST]
	elif hand_node:
		wt = hand_node.transform

	wt = _center * wt
	var wq: Quaternion = wt.basis.get_rotation_quaternion()
	hand_data["wrist"] = {
		"pos": [snappedf(wt.origin.x, 0.0001), snappedf(wt.origin.y, 0.0001), snappedf(wt.origin.z, 0.0001)],
		"rot": [snappedf(wq.x, 0.0001), snappedf(wq.y, 0.0001), snappedf(wq.z, 0.0001), snappedf(wq.w, 0.0001)]
	}

	# 2. Finger chains (relative transforms from OpenXR tracker joints)
	var chains := {}
	for finger in FINGER_CHAINS.keys():
		var chain_names: Array = FINGER_CHAINS[finger]
		var chain_data := []

		for idx in range(chain_names.size()):
			var bone_short_name: String = chain_names[idx]
			var rot: Quaternion = Quaternion.IDENTITY
			var length: float = 0.0
			var pos: Vector3 = Vector3.ZERO   # joint position in the parent joint frame (metres) - like BONE_UPDATE_FULL
			var valid: bool = false

			var joint: int = JOINT_MAP.get(bone_short_name, -1)
			var parent_joint: int = JOINT_PARENTS.get(joint, -1)

			if joint != -1 and parent_joint != -1 and transforms.has(joint) and inv_transforms.has(parent_joint):
				var rel_xf: Transform3D = inv_transforms[parent_joint] * transforms[joint]
				rot = rel_xf.basis.get_rotation_quaternion()
				length = rel_xf.origin.length()
				pos = rel_xf.origin
				var fj: int = joint_flags.get(joint, 0)
				var fp: int = joint_flags.get(parent_joint, 0)
				valid = (fj & _JOINT_VALID_FLAGS) == _JOINT_VALID_FLAGS and (fp & _JOINT_VALID_FLAGS) == _JOINT_VALID_FLAGS
			elif skeleton:
				var bone_idx: int = skeleton.find_bone(prefix + bone_short_name)
				if bone_idx != -1:
					rot = skeleton.get_bone_pose_rotation(bone_idx)
					length = skeleton.get_bone_rest(bone_idx).origin.length()
					pos = skeleton.get_bone_pose_position(bone_idx)

			var entry := {
				"name": bone_short_name,
				"rot": [snappedf(rot.x, 0.0001), snappedf(rot.y, 0.0001), snappedf(rot.z, 0.0001), snappedf(rot.w, 0.0001)],
				"length": snappedf(length, 0.0001),
				"pos": [snappedf(pos.x, 0.0001), snappedf(pos.y, 0.0001), snappedf(pos.z, 0.0001)],
				"valid": valid
			}
			if send_model_bones:
				var mr = _model_rot[prefix].get(bone_short_name)
				if mr != null:
					entry["model_rot"] = [snappedf(mr.x, 0.0001), snappedf(mr.y, 0.0001), snappedf(mr.z, 0.0001), snappedf(mr.w, 0.0001)]
			chain_data.append(entry)

		chains[finger] = chain_data

	hand_data["chains"] = chains
	return hand_data


func _extract_hand_fallback(prefix: String, hand_node: XRNode3D, skeleton: Skeleton3D) -> Dictionary:
	var hand_data := {}
	var wt: Transform3D = hand_node.transform
	wt = _center * wt
	var wq: Quaternion = wt.basis.get_rotation_quaternion()
	hand_data["wrist"] = {
		"pos": [snappedf(wt.origin.x, 0.0001), snappedf(wt.origin.y, 0.0001), snappedf(wt.origin.z, 0.0001)],
		"rot": [snappedf(wq.x, 0.0001), snappedf(wq.y, 0.0001), snappedf(wq.z, 0.0001), snappedf(wq.w, 0.0001)]
	}

	var chains := {}
	for finger in FINGER_CHAINS.keys():
		var chain_names: Array = FINGER_CHAINS[finger]
		var chain_data := []

		for idx in range(chain_names.size()):
			var bone_short_name: String = chain_names[idx]
			var bone_idx: int = skeleton.find_bone(prefix + bone_short_name)
			if bone_idx == -1:
				continue

			var rot: Quaternion = skeleton.get_bone_pose_rotation(bone_idx)
			var length: float = skeleton.get_bone_rest(bone_idx).origin.length()

			chain_data.append({
				"name": bone_short_name,
				"rot": [snappedf(rot.x, 0.0001), snappedf(rot.y, 0.0001), snappedf(rot.z, 0.0001), snappedf(rot.w, 0.0001)],
				"length": snappedf(length, 0.0001)
			})

		chains[finger] = chain_data

	hand_data["chains"] = chains
	return hand_data


# --- CONSUMER (Worker thread: sends ONLY latest frame) ---
func _consumer_thread_func() -> void:
	var udp := PacketPeerUDP.new()

	if enable_broadcast:
		udp.set_broadcast_enabled(true)
		udp.set_dest_address("255.255.255.255", target_port)
	else:
		udp.set_dest_address(target_ip, target_port)

	while _running:
		_semaphore.wait()

		if not _running:
			break

		var frame_to_send: Dictionary = {}
		_mutex.lock()
		if _has_new_frame:
			frame_to_send = _latest_frame
			_has_new_frame = false # Marked consumed
		_mutex.unlock()

		if not frame_to_send.is_empty():
			if use_binary:
				udp.put_packet(_encode_binary(frame_to_send))
			else:
				udp.put_packet(JSON.stringify(frame_to_send).to_utf8_buffer())

	udp.close()


func _put_floats(buf: StreamPeerBuffer, arr, n: int, default_last: float = 0.0) -> void:
	# writes n float32 values from an Array (missing values -> 0, last one -> default_last)
	for i in range(n):
		var v: float = default_last if i == n - 1 else 0.0
		if arr is Array and i < arr.size():
			v = float(arr[i])
		buf.put_float(v)


func _encode_binary(frame: Dictionary) -> PackedByteArray:
	var hands := []
	var flags := 0
	if frame.has("head"):
		flags |= 1
	if frame.has("left"):
		flags |= 2
		hands.append(frame["left"])
	if frame.has("right"):
		flags |= 4
		hands.append(frame["right"])

	var joint_names: Array = []
	for finger in FINGER_CHAINS.keys():
		joint_names.append_array(FINGER_CHAINS[finger])

	# per hand: name -> entry
	var maps := []
	var has_model := false
	for h in hands:
		var m := {}
		var chains: Dictionary = h.get("chains", {})
		for finger in chains.keys():
			for e in chains[finger]:
				m[e["name"]] = e
				if e.has("model_rot"):
					has_model = true
		maps.append(m)
	if has_model:
		flags |= 8

	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_data(QHND_MAGIC.to_ascii_buffer())
	buf.put_u8(QHND_VERSION)
	buf.put_u8(flags)
	buf.put_u16(joint_names.size())
	buf.put_u32(int(frame.get("time", 0)) & 0xFFFFFFFF)

	if flags & 1:
		_put_floats(buf, frame["head"].get("pos"), 3)
		_put_floats(buf, frame["head"].get("rot"), 4, 1.0)

	for hi in range(hands.size()):
		var h: Dictionary = hands[hi]
		var m: Dictionary = maps[hi]
		var mask := 0
		for ji in range(joint_names.size()):
			var e = m.get(joint_names[ji])
			if e != null and e.get("valid", true):
				mask |= (1 << ji)
		buf.put_u32(mask)
		var w: Dictionary = h.get("wrist", {})
		_put_floats(buf, w.get("pos"), 3)
		_put_floats(buf, w.get("rot"), 4, 1.0)
		for jn in joint_names:
			var e = m.get(jn, {})
			_put_floats(buf, e.get("rot"), 4, 1.0)
			_put_floats(buf, e.get("pos"), 3)
		if flags & 8:
			for jn in joint_names:
				var e = m.get(jn, {})
				_put_floats(buf, e.get("model_rot", e.get("rot")), 4, 1.0)

	return buf.data_array


func _exit_tree() -> void:
	if _running:
		_running = false
		_semaphore.post()
		if _thread.is_started():
			_thread.wait_to_finish()
		print("[HandStreamer] Worker thread terminated cleanly.")
