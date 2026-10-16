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

var xr_interface: XRInterface = null
var passthrough_active: bool = false
var passthrough_retry_count: int = 0


func _ready() -> void:
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


func _process(_delta: float) -> void:
	# Retry enabling passthrough up to 5 times if session was still starting
	if not passthrough_active and passthrough_retry_count < 5:
		_setup_passthrough()

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

	if l_active and r_active:
		status_label.text = "Hands: Both Active" + stream_info
	elif l_active:
		status_label.text = "Hands: Left Active" + stream_info
	elif r_active:
		status_label.text = "Hands: Right Active" + stream_info
	else:
		status_label.text = "Looking for hands..." + stream_info
