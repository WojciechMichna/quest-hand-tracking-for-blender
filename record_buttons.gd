extends Node3D
class_name RecordButtons
## Two touch buttons in front of the user, a bit above the head, left and right. Placed once
## (like the mirror) where the user stands and looks when the VR scene starts; they stay there.
## Touching either with an index fingertip
## toggles recording: "Record Start" <-> "Record Stop" and sends a QCTL packet to the PC.
## Start begins with a COUNTDOWN_SEC countdown (time to get into the pose) shown in front of the eyes,
## then QCTL record_start is sent and "REC m:ss" stays in view until Stop (sent immediately).
## After a trigger, touches are ignored for DEBOUNCE_SEC (finger resting on the button / jitter).

const DEBOUNCE_SEC := 5.0
const BUTTON_SIZE := Vector3(0.16, 0.06, 0.02)
const TOUCH_RADIUS := 0.06          # fingertip distance to the button centre (m)
const OFFSET_UP := 0.20             # above the eyes
const OFFSET_SIDE := 0.30           # to the left / right
const OFFSET_FWD := 0.45            # in front (arm's reach)
const COUNTDOWN_SEC := 3.0

var streamer: HandStreamer = null
var camera: XRCamera3D = null
var recording: bool = false        # true from the touch (countdown included) until Stop
var _countdown: float = 0.0         # > 0: counting down, record_start not sent yet
var _rec_time: float = 0.0
var _hud: Label3D = null            # countdown / REC indicator, fixed in front of the eyes
var _cooldown: float = 0.0
var _buttons: Array = []            # [{node, label, mat, side}]
var _placed: bool = false


func _ready() -> void:
	for side in [-1.0, 1.0]:
		var root := Node3D.new()
		root.name = "RecordButton%s" % ("L" if side < 0 else "R")
		add_child(root)
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = BUTTON_SIZE
		mesh.mesh = box
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material_override = mat
		root.add_child(mesh)
		var lbl := Label3D.new()
		lbl.font_size = 28
		lbl.pixel_size = 0.0012
		lbl.outline_size = 6
		lbl.position = Vector3(0, 0, BUTTON_SIZE.z * 0.5 + 0.002)
		root.add_child(lbl)
		_buttons.append({"node": root, "label": lbl, "mat": mat, "side": side})
	_hud = Label3D.new()
	_hud.name = "RecordHud"
	_hud.no_depth_test = true
	_hud.render_priority = 10
	_hud.font_size = 96
	_hud.pixel_size = 0.0008
	_hud.outline_size = 12
	_hud.visible = false
	if camera:
		camera.add_child(_hud)
	else:
		add_child(_hud)
	_refresh()


func _refresh() -> void:
	for b in _buttons:
		if _countdown > 0.0:
			b["label"].text = "Get ready %d" % ceili(_countdown)
		else:
			b["label"].text = "Record Stop" if recording else "Record Start"
		var c: Color = Color(0.85, 0.15, 0.15) if recording else Color(0.15, 0.55, 0.25)
		if _cooldown > 0.0:
			c = c.darkened(0.45)
		b["mat"].albedo_color = c


func _fingertips() -> Array:
	var tips: Array = []
	var origin_xf: Transform3D = get_parent().global_transform if get_parent() is Node3D else Transform3D()
	for name in [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]:
		var t = XRServer.get_tracker(name)
		if t and t.has_tracking_data:
			var f: int = t.get_hand_joint_flags(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
			if f & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID:
				tips.append(origin_xf * t.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin)
	return tips


func _update_hud(delta: float) -> void:
	if _countdown > 0.0:
		var before := ceili(_countdown)
		_countdown -= delta
		if _countdown <= 0.0:
			_countdown = 0.0
			_rec_time = 0.0
			if streamer:
				streamer.send_control(HandStreamer.CTRL_RECORD_START)
			print("[VR] Record START")
			_refresh()
		elif ceili(_countdown) != before:
			_refresh()
	elif recording:
		_rec_time += delta
	if _countdown > 0.0:
		_hud.visible = true
		_hud.text = str(ceili(_countdown))
		_hud.modulate = Color(1.0, 0.75, 0.2)
		_hud.font_size = 160
		_hud.position = Vector3(0, 0, -0.6)
	elif recording:
		_hud.visible = true
		var sec := int(_rec_time)
		_hud.text = "REC %d:%02d" % [int(sec / 60.0), sec % 60]
		_hud.modulate = Color(1.0, 0.2, 0.2)
		_hud.font_size = 48
		_hud.position = Vector3(0, 0.17, -0.6)
	else:
		_hud.visible = false


func _process(delta: float) -> void:
	if camera == null:
		return
	_update_hud(delta)
	if not _placed:
		place()
		if not _placed:
			return
	# touch
	var was_cooling := _cooldown > 0.0
	if _cooldown > 0.0:
		_cooldown -= delta
	if _cooldown <= 0.0:
		for tip in _fingertips():
			for b in _buttons:
				if (tip as Vector3).distance_to((b["node"] as Node3D).global_position) < TOUCH_RADIUS:
					_toggle()
					return
	if was_cooling and _cooldown <= 0.0:
		_refresh()


## Puts the buttons in front of the current head position/direction (call again to move them).
func place() -> void:
	var cam: Transform3D = camera.global_transform
	if cam.origin.y - (get_parent() as Node3D).global_position.y < 0.5:
		return      # head not tracked yet
	var fwd: Vector3 = -cam.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-4:
		fwd = Vector3(0, 0, -1)
	var yaw := Basis.looking_at(fwd.normalized(), Vector3.UP)
	for b in _buttons:
		var node: Node3D = b["node"]
		var pos: Vector3 = cam.origin + yaw * Vector3(b["side"] * OFFSET_SIDE, OFFSET_UP, -OFFSET_FWD)
		# face the user: the label is on the +Z side of the button
		node.global_transform = Transform3D(Basis.looking_at(cam.origin - pos, Vector3.UP, true), pos)
	_placed = true
	print("[VR] Record buttons placed in front of the user")


func _toggle() -> void:
	recording = not recording
	_cooldown = DEBOUNCE_SEC
	if recording:
		_countdown = COUNTDOWN_SEC          # record_start is sent when it reaches 0 (_update_hud)
		print("[VR] Record countdown")
	else:
		var started := _countdown <= 0.0
		_countdown = 0.0
		if started and streamer:
			streamer.send_control(HandStreamer.CTRL_RECORD_STOP)
		print("[VR] Record STOP" if started else "[VR] Record cancelled during countdown")
	_refresh()
