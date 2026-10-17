extends Node3D
## VR Startup Menu on Meta Quest 3.
## Initializes OpenXR immediately so headset never drops frames.
## Persists Server IP in user:// and provides interactive VR controls. Streaming starts only on START NOW.

@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var panel: Node3D = $XROrigin3D/Panel
@onready var reticle: MeshInstance3D = $XROrigin3D/Panel/Reticle
@onready var ip_display: Label3D = $XROrigin3D/Panel/IPValue
@onready var countdown_lbl: Label3D = $XROrigin3D/Panel/CountdownLabel
@onready var status_lbl: Label3D = $XROrigin3D/Panel/StatusLabel

@onready var left_hand_node: XRNode3D = $XROrigin3D/LeftHand
@onready var right_hand_node: XRNode3D = $XROrigin3D/RightHand
@onready var left_controller: XRController3D = $XROrigin3D/LeftController
@onready var right_controller: XRController3D = $XROrigin3D/RightController

const CONFIG_PATH: String = "user://stream_config.json"
const DEFAULT_IP: String = "192.168.0.223"
const DEFAULT_PORT: int = 5005

const PANEL_HALF_W: float = 0.325
const PANEL_HALF_H: float = 0.31
const PANEL_DISTANCE: float = 0.65      # metres in front of the eyes
const PANEL_REANCHOR_DIST: float = 1.2   # panel further than this (headset was on the desk) -> move it
const PANEL_REANCHOR_ANGLE: float = 70.0 # or out of view by more than this (degrees)

var current_ip: String = DEFAULT_IP
var xr_interface: XRInterface = null
var countdown: float = 30.0
var auto_start_active: bool = false     # no auto-start: user presses START NOW with the headset on
var is_starting: bool = false
var panel_positioned: bool = false

var buttons: Array = []
var button_nodes: Dictionary = {}
var press_cooldown: float = 0.0

var _was_pinching: bool = false
var _right_skeleton: Skeleton3D = null
var _left_skeleton: Skeleton3D = null

# Real-time Bone Attachments pinned directly to the hand skeleton bones
var _right_tip_attach: BoneAttachment3D = null
var _left_tip_attach: BoneAttachment3D = null
var _right_thumb_attach: BoneAttachment3D = null
var _left_thumb_attach: BoneAttachment3D = null


func _ready() -> void:
	# 1. Initialize OpenXR immediately - REQUIRED by Quest to avoid watchdog crash
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		_on_xr_started()
	elif xr_interface:
		if xr_interface.initialize():
			_on_xr_started()
		else:
			printerr("[Menu] OpenXR initialize failed!")
	else:
		printerr("[Menu] OpenXR interface not found!")

	# 2. Load persistent IP
	_load_persistent_settings()

	# 3. Build virtual 3D keypad
	_setup_keypad()
	_update_ui()


func _on_xr_started() -> void:
	get_viewport().use_xr = true
	get_viewport().transparent_bg = false
	print("[Menu] OpenXR initialized. Viewport marked use_xr = true.")


func _load_persistent_settings() -> void:
	if FileAccess.file_exists(CONFIG_PATH):
		var file: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.READ)
		if file:
			var txt: String = file.get_as_text()
			var json: Variant = JSON.parse_string(txt)
			if json is Dictionary and json.has("target_ip"):
				current_ip = str(json["target_ip"])
			file.close()
	else:
		_save_persistent_settings()


func _save_persistent_settings() -> void:
	var cfg: Dictionary = {
		"target_ip": current_ip,
		"target_port": DEFAULT_PORT,
		"enable_broadcast": false
	}
	var file: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(cfg, "\t"))
		file.close()
		print("[Menu] Saved persistent settings to user://: ", current_ip)


func _setup_keypad() -> void:
	# Keypad definition: columns [-0.15, -0.05, 0.05, 0.15]
	var keys: Array = [
		{"id": "1", "label": "1", "x": -0.15, "y": 0.00, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": "2", "label": "2", "x": -0.05, "y": 0.00, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": "3", "label": "3", "x": 0.05, "y": 0.00, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": ".", "label": ".", "x": 0.15, "y": 0.00, "w": 0.08, "h": 0.05, "type": "num"},

		{"id": "4", "label": "4", "x": -0.15, "y": -0.065, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": "5", "label": "5", "x": -0.05, "y": -0.065, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": "6", "label": "6", "x": 0.05, "y": -0.065, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": "0", "label": "0", "x": 0.15, "y": -0.065, "w": 0.08, "h": 0.05, "type": "num"},

		{"id": "7", "label": "7", "x": -0.15, "y": -0.13, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": "8", "label": "8", "x": -0.05, "y": -0.13, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": "9", "label": "9", "x": 0.05, "y": -0.13, "w": 0.08, "h": 0.05, "type": "num"},
		{"id": "DEL", "label": "DEL", "x": 0.15, "y": -0.13, "w": 0.08, "h": 0.05, "type": "del"},

		{"id": "RESET_IP", "label": "RESET IP", "x": -0.12, "y": -0.20, "w": 0.16, "h": 0.055, "type": "reset"},
		{"id": "START_BTN", "label": "START NOW >", "x": 0.12, "y": -0.20, "w": 0.22, "h": 0.055, "type": "start"}
	]

	var keypad_parent: Node3D = Node3D.new()
	keypad_parent.name = "Keypad"
	panel.add_child(keypad_parent)

	for k in keys:
		var k_id: String = str(k["id"])
		var k_lbl: String = str(k["label"])
		var k_x: float = float(k["x"])
		var k_y: float = float(k["y"])
		var k_w: float = float(k["w"])
		var k_h: float = float(k["h"])
		var k_type: String = str(k["type"])

		var btn_mesh: MeshInstance3D = MeshInstance3D.new()
		var qm: QuadMesh = QuadMesh.new()
		qm.size = Vector2(k_w, k_h)
		btn_mesh.mesh = qm
		btn_mesh.position = Vector3(k_x, k_y, 0.01)

		var mat_norm: StandardMaterial3D = StandardMaterial3D.new()
		var mat_hov: StandardMaterial3D = StandardMaterial3D.new()

		if k_type == "start":
			mat_norm.albedo_color = Color(0.12, 0.65, 0.22)
			mat_norm.emission_enabled = true
			mat_norm.emission = Color(0.08, 0.35, 0.12)

			mat_hov.albedo_color = Color(0.20, 0.95, 0.35)
			mat_hov.emission_enabled = true
			mat_hov.emission = Color(0.25, 0.85, 0.35)
		elif k_type == "del":
			mat_norm.albedo_color = Color(0.55, 0.18, 0.18)
			mat_norm.emission_enabled = true
			mat_norm.emission = Color(0.2, 0.05, 0.05)

			mat_hov.albedo_color = Color(0.85, 0.25, 0.25)
			mat_hov.emission_enabled = true
			mat_hov.emission = Color(0.65, 0.15, 0.15)
		elif k_type == "reset":
			mat_norm.albedo_color = Color(0.22, 0.28, 0.40)

			mat_hov.albedo_color = Color(0.38, 0.50, 0.72)
			mat_hov.emission_enabled = true
			mat_hov.emission = Color(0.2, 0.3, 0.5)
		else:
			mat_norm.albedo_color = Color(0.18, 0.22, 0.32)

			mat_hov.albedo_color = Color(0.35, 0.55, 0.85)
			mat_hov.emission_enabled = true
			mat_hov.emission = Color(0.25, 0.45, 0.75)

		btn_mesh.material_override = mat_norm

		var lbl: Label3D = Label3D.new()
		lbl.text = k_lbl
		lbl.font_size = 28 if k_type == "num" or k_type == "del" else 22
		lbl.pixel_size = 0.001
		lbl.position = Vector3(0, 0, 0.005)
		lbl.outline_size = 4
		btn_mesh.add_child(lbl)

		keypad_parent.add_child(btn_mesh)
		button_nodes[k_id] = btn_mesh
		buttons.append({
			"id": k_id,
			"pos_2d": Vector2(k_x, k_y),
			"size": Vector2(k_w, k_h),
			"mesh": btn_mesh,
			"mat_norm": mat_norm,
			"mat_hov": mat_hov
		})


func _update_ui() -> void:
	ip_display.text = current_ip


func _process(delta: float) -> void:
	if is_starting:
		return

	if press_cooldown > 0.0:
		press_cooldown -= delta

	# 1. World-anchor panel in front of headset on first valid tracking pose
	if not panel_positioned and xr_camera:
		if xr_camera.global_position.length_squared() > 0.001 or xr_camera.global_transform.origin.length_squared() > 0.001:
			_recenter_panel()
			panel_positioned = true
	elif panel_positioned and xr_camera and _panel_lost():
		# app was started with the headset lying somewhere -> bring the panel in front of the user
		_recenter_panel()

	# 2. Auto-start countdown
	if auto_start_active:
		countdown -= delta
		if countdown <= 0.0:
			_start_vr()
			return
		countdown_lbl.text = "Auto-starting in %d s... (Pinch or tap Start)" % int(ceil(countdown))

	# 3. Find hand skeletons and ensure BoneAttachment3D markers are pinned to index fingertips
	_ensure_skeletons_and_attachments()

	# 4. Ray & Touch intersection with panel
	var hit_data: Dictionary = _detect_interaction_hit()

	# 5. Button hover highlighting & Reticle visibility
	var hovered_id: String = ""
	if hit_data["valid"]:
		# When touching with finger, the fingertip dot IS the cursor, so hide reticle to avoid duplicates
		if hit_data.get("is_touch", false):
			reticle.visible = false
		else:
			reticle.visible = true
			reticle.position = Vector3(hit_data["pos"].x, hit_data["pos"].y, 0.015)
		hovered_id = _find_button_at(hit_data["pos"])
	else:
		reticle.visible = false

	for b in buttons:
		var is_hov: bool = (str(b["id"]) == hovered_id)
		b["mesh"].material_override = b["mat_hov"] if is_hov else b["mat_norm"]

	# 6. Check Click inputs (Touch, Pinch, Controller Trigger, Keyboard)
	_handle_clicks(hovered_id, hit_data)


func _recenter_panel() -> void:
	if not xr_camera:
		return
	var cam_pos: Vector3 = xr_camera.global_position
	var forward: Vector3 = -xr_camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.01:
		forward = Vector3(0, 0, -1)
	else:
		forward = forward.normalized()

	# Place panel PANEL_DISTANCE in front of camera, slightly below eye height
	panel.global_position = cam_pos + forward * PANEL_DISTANCE + Vector3(0, -0.14, 0)
	panel.look_at(cam_pos + Vector3(0, -0.05, 0), Vector3.UP)
	panel.rotate_object_local(Vector3.UP, PI)
	print("[Menu] Anchored panel in world space at: ", panel.global_position)


var _out_of_view_time: float = 0.0
var _user_interacted: bool = false


func _panel_lost() -> bool:
	var to_panel: Vector3 = panel.global_position - xr_camera.global_position
	if to_panel.length() > PANEL_REANCHOR_DIST:
		return true
	# out of view for 1.5 s - only until the user touched the panel (then it stays where it is)
	if _user_interacted:
		return false
	var fwd: Vector3 = -xr_camera.global_transform.basis.z
	if to_panel.length() > 0.01 and rad_to_deg(fwd.angle_to(to_panel)) > PANEL_REANCHOR_ANGLE:
		_out_of_view_time += get_process_delta_time()
	else:
		_out_of_view_time = 0.0
	if _out_of_view_time > 1.5:
		_out_of_view_time = 0.0
		return true
	return false


func _ensure_skeletons_and_attachments() -> void:
	if not _right_skeleton and right_hand_node:
		_right_skeleton = _find_skeleton(right_hand_node)
	if not _left_skeleton and left_hand_node:
		_left_skeleton = _find_skeleton(left_hand_node)

	# Right hand attachments (Pinned directly to bones)
	if _right_skeleton:
		if not _right_tip_attach:
			_right_tip_attach = _create_bone_attachment(_right_skeleton, "RightIndexTip", true, Color(0.15, 0.95, 1.0))
		if not _right_thumb_attach:
			_right_thumb_attach = _create_bone_attachment(_right_skeleton, "RightThumbTip", false, Color.WHITE)

	# Left hand attachments (Pinned directly to bones)
	if _left_skeleton:
		if not _left_tip_attach:
			_left_tip_attach = _create_bone_attachment(_left_skeleton, "LeftIndexTip", true, Color(1.0, 0.85, 0.15))
		if not _left_thumb_attach:
			_left_thumb_attach = _create_bone_attachment(_left_skeleton, "LeftThumbTip", false, Color.WHITE)


func _create_bone_attachment(skel: Skeleton3D, bone_name: String, add_marker: bool, marker_color: Color) -> BoneAttachment3D:
	var idx: int = skel.find_bone(bone_name)
	if idx == -1:
		printerr("[Menu] Bone not found in skeleton: ", bone_name)
		return null

	var attach := BoneAttachment3D.new()
	attach.name = bone_name + "Attachment"
	attach.bone_name = bone_name
	attach.bone_idx = idx
	skel.add_child(attach)

	if add_marker:
		var tip_mesh := MeshInstance3D.new()
		tip_mesh.name = "TipDot"
		var sm := SphereMesh.new()
		sm.radius = 0.007 # 7mm radius sphere (sits directly on fingertip)
		sm.height = 0.014
		tip_mesh.mesh = sm

		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = marker_color
		tip_mesh.material_override = mat

		attach.add_child(tip_mesh)

	print("[Menu] Created BoneAttachment3D for ", bone_name, " at bone index ", idx)
	return attach


func _detect_interaction_hit() -> Dictionary:
	# Priority 1: Direct Fingertip Poke (Physical Touch with index finger)
	if _right_tip_attach and _is_hand_tracked("right"):
		var r_touch := _test_direct_touch(_right_tip_attach)
		if r_touch["valid"]:
			return r_touch

	if _left_tip_attach and _is_hand_tracked("left"):
		var l_touch := _test_direct_touch(_left_tip_attach)
		if l_touch["valid"]:
			return l_touch

	# Priority 2: Hand Pointing Ray (Right Hand: wrist towards index tip)
	if _right_tip_attach and _is_hand_tracked("right") and right_hand_node:
		var r_ray := _test_hand_ray(_right_tip_attach, right_hand_node)
		if r_ray["valid"]:
			return r_ray

	# Priority 3: Hand Pointing Ray (Left Hand: wrist towards index tip)
	if _left_tip_attach and _is_hand_tracked("left") and left_hand_node:
		var l_ray := _test_hand_ray(_left_tip_attach, left_hand_node)
		if l_ray["valid"]:
			return l_ray

	# Priority 4: Controller Ray
	if right_controller and right_controller.get_is_active():
		var cr_hit := _intersect_panel(right_controller.global_position, -right_controller.global_transform.basis.z)
		if cr_hit["valid"]:
			return cr_hit

	if left_controller and left_controller.get_is_active():
		var cl_hit := _intersect_panel(left_controller.global_position, -left_controller.global_transform.basis.z)
		if cl_hit["valid"]:
			return cl_hit

	# Priority 5: Head Gaze Ray (Always works when looking at buttons)
	if xr_camera:
		var cam_pos: Vector3 = xr_camera.global_position
		var cam_dir: Vector3 = -xr_camera.global_transform.basis.z.normalized()
		var gaze_hit := _intersect_panel(cam_pos, cam_dir)
		if gaze_hit["valid"]:
			return gaze_hit

	return {"valid": false}


func _test_direct_touch(attach: BoneAttachment3D) -> Dictionary:
	if not attach or not attach.is_visible_in_tree():
		return {"valid": false}
	var tip_world: Vector3 = attach.global_position
	if tip_world.length_squared() < 0.001:
		return {"valid": false}

	var tip_local: Vector3 = panel.global_transform.affine_inverse() * tip_world
	# If fingertip dot is within 2.5 cm in front or behind panel surface
	if absf(tip_local.z) < 0.025:
		if absf(tip_local.x) <= PANEL_HALF_W and absf(tip_local.y) <= PANEL_HALF_H:
			return {"valid": true, "pos": Vector2(tip_local.x, tip_local.y), "is_touch": true}
	return {"valid": false}


func _test_hand_ray(attach: BoneAttachment3D, hand_node: XRNode3D) -> Dictionary:
	if not attach or not hand_node:
		return {"valid": false}
	var tip_pos: Vector3 = attach.global_position
	var wrist_pos: Vector3 = hand_node.global_position
	if tip_pos.distance_squared_to(wrist_pos) < 0.0001:
		return {"valid": false}
	var dir: Vector3 = (tip_pos - wrist_pos).normalized()
	return _intersect_panel(tip_pos, dir)


func _intersect_panel(ray_origin: Vector3, ray_dir: Vector3) -> Dictionary:
	var panel_n: Vector3 = panel.global_transform.basis.z.normalized()
	var denom: float = ray_dir.dot(panel_n)
	# Ray pointing towards panel front
	if denom < -0.05:
		var d: float = (panel.global_position - ray_origin).dot(panel_n) / denom
		if d > 0.05 and d < 3.5:
			var world_hit: Vector3 = ray_origin + ray_dir * d
			var local_hit: Vector3 = panel.global_transform.affine_inverse() * world_hit
			if absf(local_hit.x) <= PANEL_HALF_W and absf(local_hit.y) <= PANEL_HALF_H:
				return {"valid": true, "pos": Vector2(local_hit.x, local_hit.y), "is_touch": false}
	return {"valid": false}


func _find_button_at(pos: Vector2) -> String:
	for b in buttons:
		var b_pos: Vector2 = b["pos_2d"]
		var b_sz: Vector2 = b["size"]
		if absf(pos.x - b_pos.x) <= b_sz.x * 0.5 and absf(pos.y - b_pos.y) <= b_sz.y * 0.5:
			return str(b["id"])
	return ""


func _handle_clicks(hovered_id: String, hit_data: Dictionary) -> void:
	# 1. Direct touch press
	if hit_data.get("is_touch", false) and hovered_id != "":
		if press_cooldown <= 0.0:
			_trigger_button(hovered_id)
			press_cooldown = 0.28
			return

	# 2. Hand pinch detection (distance between thumb and index finger attachments)
	var is_pinching: bool = (
		(_is_hand_tracked("right") and _is_pinching_hand(_right_thumb_attach, _right_tip_attach)) or
		(_is_hand_tracked("left") and _is_pinching_hand(_left_thumb_attach, _left_tip_attach))
	)
	var pinch_just_pressed: bool = is_pinching and not _was_pinching
	_was_pinching = is_pinching

	if pinch_just_pressed and press_cooldown <= 0.0:
		if hovered_id != "":
			_trigger_button(hovered_id)
			press_cooldown = 0.25
			return
		elif auto_start_active:
			_start_vr()
			return

	# 3. Controller Trigger / Generic click
	var trigger_pressed: bool = Input.is_action_just_pressed("ui_accept") or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if right_controller and right_controller.is_button_pressed(&"trigger_click"):
		trigger_pressed = true
	if left_controller and left_controller.is_button_pressed(&"trigger_click"):
		trigger_pressed = true

	if trigger_pressed and press_cooldown <= 0.0:
		if hovered_id != "":
			_trigger_button(hovered_id)
			press_cooldown = 0.25
			return
		elif auto_start_active:
			_start_vr()
			return


func _is_pinching_hand(thumb_attach: BoneAttachment3D, index_attach: BoneAttachment3D) -> bool:
	if not thumb_attach or not index_attach:
		return false
	var t_pos: Vector3 = thumb_attach.global_position
	var i_pos: Vector3 = index_attach.global_position
	if t_pos == Vector3.ZERO or i_pos == Vector3.ZERO:
		return false
	return t_pos.distance_to(i_pos) < 0.038


func _trigger_button(id: String) -> void:
	if id == "START_BTN":
		_start_vr()
		return

	# Stop countdown as soon as user interacts
	auto_start_active = false
	_user_interacted = true
	countdown_lbl.text = "Type the PC IP, then tap START NOW."

	if id == "RESET_IP":
		current_ip = DEFAULT_IP
		_update_ui()
		status_lbl.text = "Reset IP to default: %s" % DEFAULT_IP
	elif id == "DEL":
		if current_ip.length() > 0:
			current_ip = current_ip.substr(0, current_ip.length() - 1)
			_update_ui()
			status_lbl.text = "Deleted character"
	else:
		if current_ip.length() < 24:
			current_ip += id
			_update_ui()
			status_lbl.text = "Typed: %s" % id

	_flash_button(id)


func _flash_button(id: String) -> void:
	if not button_nodes.has(id):
		return
	var mesh_inst: MeshInstance3D = button_nodes[id]
	var flash_mat: StandardMaterial3D = StandardMaterial3D.new()
	flash_mat.albedo_color = Color(1.0, 1.0, 1.0)
	flash_mat.emission_enabled = true
	flash_mat.emission = Color(1.0, 1.0, 1.0)
	mesh_inst.material_override = flash_mat

	var tw: Tween = create_tween()
	tw.tween_interval(0.10)
	tw.tween_callback(func():
		for b in buttons:
			if str(b["id"]) == id:
				mesh_inst.material_override = b["mat_norm"]
				break
	)


func _is_hand_tracked(side: String) -> bool:
	var trk_name: StringName = &"/user/hand_tracker/" + side
	var trk = XRServer.get_tracker(trk_name)
	if trk:
		if "has_tracking_data" in trk:
			return bool(trk.has_tracking_data)
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		var key_str: String = OS.get_keycode_string(event.key_label if event.key_label != KEY_NONE else event.keycode)
		if key_str in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Period", "."]:
			var ch: String = "." if (key_str == "Period" or key_str == ".") else key_str
			_trigger_button(ch)
		elif event.keycode == KEY_BACKSPACE:
			_trigger_button("DEL")
		elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			_start_vr()
		elif event.keycode == KEY_R:
			_trigger_button("RESET_IP")


func _start_vr() -> void:
	if is_starting:
		return
	is_starting = true
	_save_persistent_settings()
	status_lbl.text = "Starting VR Streamer for %s..." % current_ip
	print("[Menu] Starting main_vr.tscn with IP: ", current_ip)
	get_tree().change_scene_to_file("res://main_vr.tscn")


func _find_skeleton(n: Node) -> Skeleton3D:
	if not n:
		return null
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s: Skeleton3D = _find_skeleton(c)
		if s:
			return s
	return null
