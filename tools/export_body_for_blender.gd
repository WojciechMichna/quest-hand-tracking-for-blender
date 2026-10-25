@tool
extends EditorScript
## Exports the avatar (assets/avatar/Avatar.glb) AS GODOT SEES IT after import retargeting
## (bones renamed to SkeletonProfileHumanoid names, rest axes overwritten to the humanoid
## convention) to a .glb for Blender. Bone names/axes then match XRBodyTracker joints 1:1.
## Run: open this file in the Script editor -> File -> Run (Ctrl+Shift+X).

const SRC := "res://assets/avatar/Avatar.glb"
const OUT := "D:/GodotProjects/GodotOculusHandsExport/blender_models/BodyHumanoid.glb"


func _run() -> void:
	var scene: PackedScene = load(SRC)
	if scene == null:
		push_error("Cannot load " + SRC)
		return
	var root: Node = scene.instantiate()
	var skel: Skeleton3D = null
	for n in root.find_children("*", "Skeleton3D", true, false):
		skel = n
		break
	if skel:
		var names: PackedStringArray
		for i in skel.get_bone_count():
			names.append(skel.get_bone_name(i))
		print("[export_body] skeleton '%s', %d bones: %s" % [skel.name, skel.get_bone_count(), ", ".join(names)])
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err != OK:
		push_error("append_from_scene failed: %d" % err)
		root.free()
		return
	err = doc.write_to_filesystem(state, OUT)
	root.free()
	if err != OK:
		push_error("write_to_filesystem failed: %d" % err)
	else:
		print("[export_body] written ", OUT)
