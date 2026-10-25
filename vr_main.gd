extends Node3D
## Main VR Entry Point with Passthrough support on Meta Quest 3.
## Initializes OpenXR, starts Passthrough (Mixed Reality), and streams hands over UDP.

@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var status_label: Label3D = $XROrigin3D/XRCamera3D/StatusLabel
@onready var left_hand: XRNode3D = $XROrigin3D/LeftHand
@onready var right_hand: XRNode3D = $XROrigin3D/RightHand
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var floor_node: Node3D = $Floor
@onready var streamer: HandStreamer = $HandStreamer
## First-person body (assets/avatar/Avatar.glb) driven by Meta body tracking. When the body is tracked it
## replaces the yellow hands; without body tracking the yellow hands are shown instead.
@onready var body_preview: Node3D = get_node_or_null("XROrigin3D/BodyPreview")
@onready var left_hand_model: Node3D = get_node_or_null("XROrigin3D/LeftHand/LeftHandModel")
@onready var right_hand_model: Node3D = get_node_or_null("XROrigin3D/RightHand/RightHandModel")
var _body_head_hidden: bool = false
## Set from the menu ("AVATAR: ON/OFF", saved in user://stream_config.json). Default off.
var show_avatar: bool = false
## Mirror on the left side (menu "MIRROR: ON/OFF"): a mirrored copy of the avatar behind a frame.
var show_mirror: bool = false
const MIRROR_DISTANCE := 1.0          # metres to the left of where the user pressed START
const AVATAR_SCENE := preload("res://assets/avatar/Avatar.glb")
var _mirror_root: Node3D = null       # mirrored avatar copy
var _mirror_frame: Node3D = null
var _mirror_reflect := Transform3D()  # reflection across the mirror plane (XROrigin space)
var _mirror_placed: bool = false
## Print [BodyDiag] lines (tracker vs avatar bone positions) every 2 s.
@export var body_diag: bool = false

var xr_interface: XRInterface = null
var passthrough_active: bool = false
var passthrough_retry_count: int = 0


func _load_avatar_setting() -> void:
	var path := "user://stream_config.json"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var cfg = JSON.parse_string(f.get_as_text())
			if cfg is Dictionary and cfg.has("show_avatar"):
				show_avatar = bool(cfg["show_avatar"])
			if cfg is Dictionary and cfg.has("show_mirror"):
				show_mirror = bool(cfg["show_mirror"])
	print("[VR] Full-body avatar: ", "on" if show_avatar else "off", ", mirror: ", "on" if show_mirror else "off")


## Avatar look: blue, 30 % transparent (alpha 0.7). Applied to the first-person avatar and the mirror.
const AVATAR_COLOR := Color(0.25, 0.55, 1.0, 0.7)
var _avatar_tinted: bool = false
var record_buttons: RecordButtons = null


func _tint_avatar(root: Node, double_sided: bool) -> void:
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = n
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var src = mi.get_active_material(si)
			var m: StandardMaterial3D = src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()
			m.albedo_color = AVATAR_COLOR
			m.albedo_texture = null
			# depth pre-pass: the avatar's own back parts do not shine through its front
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			if double_sided:
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
			mi.set_surface_override_material(si, m)


func _ready() -> void:
	_load_avatar_setting()
	record_buttons = RecordButtons.new()
	record_buttons.name = "RecordButtons"
	record_buttons.streamer = streamer
	record_buttons.camera = xr_camera
	xr_origin.add_child(record_buttons)
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("[VR] OpenXR already initialized.")
		_on_xr_started()
	elif xr_interface:
		print("[VR] Initializing OpenXR...")
		if xr_interface.initialize():
			_on_xr_started()
		else:
			_update_status("ERROR: OpenXR initialize() failed")
	else:
		_update_status("ERROR: OpenXR interface not found")


func _on_xr_started() -> void:
	get_viewport().use_xr = true
	_update_status("Quest VR Ready - Show Hands")
	_setup_passthrough()


func _setup_passthrough() -> bool:
	if passthrough_active:
		return true

	if not xr_interface:
		xr_interface = XRServer.find_interface("OpenXR")
	if not xr_interface:
		return false

	var blend_modes: Array = xr_interface.get_supported_environment_blend_modes()
	print("[VR] Checking Passthrough (supported blend modes: %s)..." % str(blend_modes))

	# 1. Godot 4.3+ OpenXR Vendors standard: ALPHA_BLEND environment mode
	if blend_modes.has(XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND):
		if xr_interface.set_environment_blend_mode(XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND):
			_apply_passthrough_visuals()
			return true

	# 2. Meta OpenXR Extension direct methods
	if xr_interface.is_passthrough_supported():
		if xr_interface.is_passthrough_enabled() or xr_interface.start_passthrough():
			_apply_passthrough_visuals()
			return true

	passthrough_retry_count += 1
	if passthrough_retry_count <= 5:
		print("[VR] Passthrough setup attempt %d failed (blend modes: %s)." % [passthrough_retry_count, str(blend_modes)])

	return false


func _apply_passthrough_visuals() -> void:
	passthrough_active = true
	get_viewport().transparent_bg = true

	if world_env and world_env.environment:
		world_env.environment.background_mode = Environment.BG_COLOR
		world_env.environment.background_color = Color(0, 0, 0, 0)
		world_env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		world_env.environment.ambient_light_color = Color(0.65, 0.65, 0.65)

	if floor_node:
		floor_node.visible = false

	print("[VR] Passthrough activated successfully on Quest 3!")


func _update_status(text: String) -> void:
	if status_label:
		status_label.text = text
	print("[VR] ", text)


var _body_modifier_added: bool = false


func _attach_body_modifier(root: Node) -> bool:
	# The XRBodyModifier3D is created in code: a node added under an instanced .fbx scene in the
	# .tscn was silently dropped (avatar stayed in T-pose).
	for n in root.find_children("*", "Skeleton3D", true, false):
		var skel: Skeleton3D = n
		if skel.find_bone("Hips") == -1:
			continue
		var mod := XRBodyModifier3D.new()
		mod.name = "XRBodyModifier3D"
		mod.body_tracker = &"/user/body_tracker"
		mod.bone_update = XRBodyModifier3D.BONE_UPDATE_FULL
		skel.add_child(mod)
		var fix := BodyRestLengths.new()     # after the body modifier: neck/head keep model length
		fix.name = "BodyRestLengths"
		skel.add_child(fix)
		print("[VR] Body modifier attached to ", skel.get_path())
		return true
	print("[VR] ", root.name, ": no humanoid Skeleton3D found")
	return false


func _ensure_body_modifier() -> void:
	if _body_modifier_added or body_preview == null:
		return
	_body_modifier_added = _attach_body_modifier(body_preview)


func _setup_mirror() -> void:
	# Called once, when body data first arrives (the user just pressed START and looks ahead).
	# Mirror plane: vertical, MIRROR_DISTANCE to the user's left, facing the user's right side.
	var cam: Camera3D = get_viewport().get_camera_3d()
	var cam_t: Transform3D = xr_origin.global_transform.affine_inverse() * cam.global_transform
	var fwd: Vector3 = -cam_t.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-6:
		fwd = Vector3(0, 0, -1)
	var frame := Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), Vector3(cam_t.origin.x, 0.0, cam_t.origin.z))
	# in the user's frame: x = right, so the mirror plane is x = -MIRROR_DISTANCE
	var flip := Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)), Vector3(-2.0 * MIRROR_DISTANCE, 0, 0))
	_mirror_reflect = frame * flip * frame.affine_inverse()

	_mirror_root = Node3D.new()
	_mirror_root.name = "BodyMirror"
	xr_origin.add_child(_mirror_root)
	_mirror_root.add_child(AVATAR_SCENE.instantiate())
	_attach_body_modifier(_mirror_root)
	# the reflection (negative scale) turns the triangles inside out -> double-sided + avatar tint
	_tint_avatar(_mirror_root, true)

	# frame: dark glass + thin border, normal pointing to the user
	_mirror_frame = Node3D.new()
	_mirror_frame.name = "MirrorFrame"
	xr_origin.add_child(_mirror_frame)
	_mirror_frame.transform = frame * Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(-MIRROR_DISTANCE - 0.01, 0, 0))
	var glass := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.4, 2.1)
	glass.mesh = q
	glass.position = Vector3(0, 1.05, 0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.65, 0.75, 0.18)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass.material_override = m
	_mirror_frame.add_child(glass)
	for e in [[Vector3(0, 2.1, 0), Vector2(1.44, 0.03)], [Vector3(0, 0.0, 0), Vector2(1.44, 0.03)],
			[Vector3(-0.71, 1.05, 0), Vector2(0.03, 2.13)], [Vector3(0.71, 1.05, 0), Vector2(0.03, 2.13)]]:
		var bar := MeshInstance3D.new()
		var bq := QuadMesh.new()
		bq.size = e[1]
		bar.mesh = bq
		bar.position = e[0] + Vector3(0, 0, 0.002)
		var bm := StandardMaterial3D.new()
		bm.albedo_color = Color(0.85, 0.85, 0.9)
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bm.cull_mode = BaseMaterial3D.CULL_DISABLED
		bar.material_override = bm
		_mirror_frame.add_child(bar)
	_mirror_placed = true
	print("[VR] Mirror placed ", MIRROR_DISTANCE, " m to the left")


func _update_mirror(bt, body_on: bool) -> void:
	if not show_mirror:
		return
	if not _mirror_placed:
		if not body_on:
			return
		_setup_mirror()
	_mirror_frame.visible = true
	_mirror_root.visible = body_on
	if body_on:
		# same placement as the first-person avatar, reflected across the mirror plane
		# (negative-determinant transform; Godot flips face culling for it)
		_mirror_root.transform = _mirror_reflect * bt.get_joint_transform(XRBodyTracker.JOINT_ROOT)


func _hide_body_head() -> void:
	# camera sits inside the avatar's head: shrink the Head bone (and hair/face skinned to it).
	# The body modifier only writes rotation/position, so this scale stays.
	if _body_head_hidden or body_preview == null:
		return
	for n in body_preview.find_children("*", "Skeleton3D", true, false):
		var skel: Skeleton3D = n
		var head: int = skel.find_bone("Head")
		if head != -1:
			skel.set_bone_pose_scale(head, Vector3.ONE * 0.001)
			_body_head_hidden = true


var _diag_t: float = 0.0
var _body_skel: Skeleton3D = null
var _post_mod := {}     # bone name -> global pose AFTER the modifiers ran (from skeleton_updated)
const _DIAG_BONES := ["Root", "Hips", "Head", "LeftHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
		"RightUpperLeg", "RightLowerLeg", "RightFoot"]


func _on_body_skeleton_updated() -> void:
	for name in _DIAG_BONES:
		var bi: int = _body_skel.find_bone(name)
		if bi != -1:
			_post_mod[name] = _body_skel.get_bone_global_pose(bi)


func _jflags(f: int) -> String:
	# O orientation valid, o orientation tracked, P position valid, p position tracked
	return "%s%s%s%s" % ["O" if f & 1 else "-", "o" if f & 2 else "-", "P" if f & 4 else "-", "p" if f & 8 else "-"]


func _knee_deg(a: Vector3, b: Vector3, c: Vector3) -> float:
	# bend at b between segments a->b and b->c (0 = straight leg)
	return rad_to_deg((b - a).angle_to(c - b))


func _v(p: Vector3) -> String:
	return "(%.2f,%.2f,%.2f)" % [p.x, p.y, p.z]


func _body_diag(bt) -> void:
	# every 2 s, one line: tracker leg joints (+ flags, knee angle) vs the avatar's leg bones
	_diag_t -= get_process_delta_time()
	if _diag_t > 0.0:
		return
	_diag_t = 2.0
	var parts: PackedStringArray
	var head_t: Vector3 = bt.get_joint_transform(XRBodyTracker.JOINT_HEAD).origin
	var hips_t: Vector3 = bt.get_joint_transform(XRBodyTracker.JOINT_HIPS).origin
	var cam_y: float = get_viewport().get_camera_3d().global_position.y - xr_origin.global_position.y
	parts.append("eyeY %.2f headY %.2f hipsY %.2f" % [cam_y, head_t.y, hips_t.y])
	for side in [["L", XRBodyTracker.JOINT_LEFT_UPPER_LEG, XRBodyTracker.JOINT_LEFT_LOWER_LEG, XRBodyTracker.JOINT_LEFT_FOOT],
			["R", XRBodyTracker.JOINT_RIGHT_UPPER_LEG, XRBodyTracker.JOINT_RIGHT_LOWER_LEG, XRBodyTracker.JOINT_RIGHT_FOOT]]:
		var th: Vector3 = bt.get_joint_transform(side[1]).origin
		var kn: Vector3 = bt.get_joint_transform(side[2]).origin
		var ft: Vector3 = bt.get_joint_transform(side[3]).origin
		parts.append("trk%s thigh%s knee%s foot%s flags %s/%s/%s knee %.0fdeg len %.2f+%.2f" % [
			side[0], _v(th), _v(kn), _v(ft),
			_jflags(int(bt.get_joint_flags(side[1]))), _jflags(int(bt.get_joint_flags(side[2]))), _jflags(int(bt.get_joint_flags(side[3]))),
			_knee_deg(th, kn, ft), th.distance_to(kn), kn.distance_to(ft)])
	# avatar (only when the avatar is shown)
	if body_preview and body_preview.visible:
		if _body_skel == null:
			for n in body_preview.find_children("*", "Skeleton3D", true, false):
				if (n as Skeleton3D).find_bone("Hips") != -1:
					_body_skel = n
					_body_skel.skeleton_updated.connect(_on_body_skeleton_updated)
		if _body_skel != null and not _post_mod.is_empty():
			var to_origin: Transform3D = xr_origin.global_transform.affine_inverse() * _body_skel.global_transform
			var P := func(name: String) -> Vector3: return (to_origin * (_post_mod.get(name, Transform3D()) as Transform3D)).origin
			for sd in ["Left", "Right"]:
				var th: Vector3 = P.call(sd + "UpperLeg")
				var kn: Vector3 = P.call(sd + "LowerLeg")
				var ft: Vector3 = P.call(sd + "Foot")
				parts.append("avatar%s thigh%s knee%s foot%s knee %.0fdeg len %.2f+%.2f" % [
					sd[0], _v(th), _v(kn), _v(ft), _knee_deg(th, kn, ft), th.distance_to(kn), kn.distance_to(ft)])
			parts.append("avatar hips%s head%s" % [_v(P.call("Hips")), _v(P.call("Head"))])
	print("[BodyDiag] ", " | ".join(parts))


func _update_body_visibility() -> bool:
	var bt = XRServer.get_tracker(&"/user/body_tracker")
	var body_on: bool = bt != null and bool(bt.has_tracking_data)
	var avatar_on: bool = body_on and show_avatar
	if body_preview:
		body_preview.visible = avatar_on
		if avatar_on:
			_ensure_body_modifier()
			_hide_body_head()
			if not _avatar_tinted:
				_tint_avatar(body_preview, false)
				_avatar_tinted = true
			# XRBodyModifier3D poses the body RELATIVE TO THE ROOT JOINT (on the floor under the hips,
			# +Z = where the user faces) and leaves moving the avatar to us: place the skeleton there.
			body_preview.transform = bt.get_joint_transform(XRBodyTracker.JOINT_ROOT)

	_update_mirror(bt, body_on)
	if body_on and body_diag:
		_body_diag(bt)
	if left_hand_model:
		left_hand_model.visible = not avatar_on
	if right_hand_model:
		right_hand_model.visible = not avatar_on
	return body_on


func _process(_delta: float) -> void:
	# Retry enabling passthrough up to 5 times if session was still starting
	if not passthrough_active and passthrough_retry_count < 5:
		_setup_passthrough()

	var body_on := _update_body_visibility()

	var l_trk = XRServer.get_tracker(&"/user/hand_tracker/left")
	var r_trk = XRServer.get_tracker(&"/user/hand_tracker/right")

	var l_active: bool = false
	var r_active: bool = false

	if l_trk:
		l_active = bool(l_trk.has_tracking_data) if "has_tracking_data" in l_trk else true
	if r_trk:
		r_active = bool(r_trk.has_tracking_data) if "has_tracking_data" in r_trk else true

	var stream_info: String = ""
	if streamer:
		stream_info = " -> %s:%d" % [streamer.target_ip, streamer.target_port]

	if body_on:
		stream_info = " | body" + stream_info
	if l_active and r_active:
		status_label.text = "Hands: Both Active" + stream_info
	elif l_active:
		status_label.text = "Hands: Left Active" + stream_info
	elif r_active:
		status_label.text = "Hands: Right Active" + stream_info
	else:
		status_label.text = "Looking for hands..." + stream_info
