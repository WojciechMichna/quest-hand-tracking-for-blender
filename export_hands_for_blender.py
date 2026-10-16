import bpy
import os

project_dir = os.path.dirname(os.path.abspath(__file__))  # repo root (run: blender -b -P export_hands_for_blender.py)
output_dir = os.path.join(project_dir, "blender_models")
os.makedirs(output_dir, exist_ok=True)

# 1. Prepare Left Hand
bpy.ops.wm.read_factory_settings(use_empty=True)
left_gltf = os.path.join(project_dir, "assets", "hands", "LeftHandHumanoid.gltf")
bpy.ops.import_scene.gltf(filepath=left_gltf)
left_blend = os.path.join(output_dir, "LeftHand.blend")
left_glb = os.path.join(output_dir, "LeftHand.glb")
bpy.ops.wm.save_as_mainfile(filepath=left_blend)
bpy.ops.export_scene.gltf(filepath=left_glb, export_format='GLB')
print("[Blender Export] LeftHand saved to .blend and .glb")

# 2. Prepare Right Hand
bpy.ops.wm.read_factory_settings(use_empty=True)
right_gltf = os.path.join(project_dir, "assets", "hands", "RightHandHumanoid.gltf")
bpy.ops.import_scene.gltf(filepath=right_gltf)
right_blend = os.path.join(output_dir, "RightHand.blend")
right_glb = os.path.join(output_dir, "RightHand.glb")
bpy.ops.wm.save_as_mainfile(filepath=right_blend)
bpy.ops.export_scene.gltf(filepath=right_glb, export_format='GLB')
print("[Blender Export] RightHand saved to .blend and .glb")

# 3. Prepare Combined Scene (Both Hands in one .blend)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=left_gltf)
bpy.ops.import_scene.gltf(filepath=right_gltf)
both_blend = os.path.join(output_dir, "BothHands.blend")
both_glb = os.path.join(output_dir, "BothHands.glb")
bpy.ops.wm.save_as_mainfile(filepath=both_blend)
bpy.ops.export_scene.gltf(filepath=both_glb, export_format='GLB')
print("[Blender Export] BothHands combined saved to .blend and .glb")
