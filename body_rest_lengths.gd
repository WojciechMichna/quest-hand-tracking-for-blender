extends SkeletonModifier3D
class_name BodyRestLengths
## Runs after XRBodyModifier3D (must be a later sibling).
## The tracker's torso joints do not sit where the avatar's bones are (Meta's neck joint points
## forward to the middle of the head, its chest joints are higher), so copying their POSITIONS
## stretched the spine and neck and pushed the head forward/up.
## Here the spine, neck and head keep the model's bone lengths (rest positions) with the tracked
## rotations; the Neck keeps its rest pose and the Head keeps the tracked WORLD orientation.
## The shoulders keep their TRACKED world position (re-expressed under the shorter spine), so
## the arms, hands and fingers stay exactly on the user's (moving the shoulders shifted the hands).

const SPINE := ["Spine", "Chest", "UpperChest"]
const SHOULDERS := ["LeftShoulder", "RightShoulder"]


func _apply() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	var hips := skel.find_bone("Hips")
	var neck := skel.find_bone("Neck")
	var head := skel.find_bone("Head")
	if hips == -1 or neck == -1 or head == -1:
		return
	var head_global_basis: Basis = skel.get_bone_global_pose(head).basis.orthonormalized()
	var shoulder_global := {}
	for n in SHOULDERS:
		var i := skel.find_bone(n)
		if i != -1:
			shoulder_global[i] = skel.get_bone_global_pose(i).origin
	# spine: rest positions, tracked rotations; rebuild the chain's global transform ourselves
	var g: Transform3D = skel.get_bone_global_pose(hips)
	for n in SPINE:
		var i := skel.find_bone(n)
		if i == -1:
			continue
		var p: Vector3 = skel.get_bone_rest(i).origin
		skel.set_bone_pose_position(i, p)
		g = g * Transform3D(Basis(skel.get_bone_pose_rotation(i)), p)
	# shoulders hang under UpperChest (end of the rebuilt chain g): keep their tracked world spot
	for i in shoulder_global:
		if skel.get_bone_parent(i) == skel.find_bone(SPINE[-1]):
			skel.set_bone_pose_position(i, g.affine_inverse() * (shoulder_global[i] as Vector3))
	# neck: model rest pose relative to the chest
	var neck_rest: Transform3D = skel.get_bone_rest(neck)
	skel.set_bone_pose_position(neck, neck_rest.origin)
	skel.set_bone_pose_rotation(neck, neck_rest.basis.get_rotation_quaternion())
	var neck_global: Transform3D = g * neck_rest
	# head: rest length, tracked world orientation
	skel.set_bone_pose_position(head, skel.get_bone_rest(head).origin)
	skel.set_bone_pose_rotation(head, (neck_global.basis.orthonormalized().inverse() * head_global_basis).get_rotation_quaternion())


func _process_modification() -> void:
	_apply()


func _process_modification_with_delta(_delta: float) -> void:
	_apply()
