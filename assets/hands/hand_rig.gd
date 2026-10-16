extends Node3D
## Automatically attaches XRHandModifier3D to the skeleton and applies yellow material.

@export var hand_tracker: StringName = &"/user/hand_tracker/left"

var skeleton: Skeleton3D = null


func _ready() -> void:
	skeleton = _find_skeleton(self)
	if skeleton:
		var modifier := XRHandModifier3D.new()
		modifier.name = "XRHandModifier3D"
		modifier.hand_tracker = hand_tracker
		modifier.bone_update = XRHandModifier3D.BONE_UPDATE_FULL
		skeleton.add_child(modifier)

		var yellow_mat := StandardMaterial3D.new()
		yellow_mat.albedo_color = Color(1.0, 0.82, 0.08, 1.0)
		yellow_mat.roughness = 0.35
		yellow_mat.metallic = 0.1
		yellow_mat.emission_enabled = true
		yellow_mat.emission = Color(0.25, 0.2, 0.0)

		_apply_material(self, yellow_mat)
		print("[HandRig] Successfully rigged: ", hand_tracker)
	else:
		printerr("[HandRig] Skeleton3D not found!")


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null


func _apply_material(n: Node, mat: Material) -> void:
	if n is MeshInstance3D:
		n.material_override = mat
	for c in n.get_children():
		_apply_material(c, mat)
