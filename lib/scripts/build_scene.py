"""
Blender 场景骨架生成脚本（阶段 4，由 dsh-scene-skeleton-pipeline 调用）。

用法：
  blender --background --factory-startup --python build_scene.py -- <spec.json>

spec.json 结构：
  {
    "title": "场景名",
    "prompt": "生成用的提示词",
    "images": ["ComfyUI 生成图的绝对路径"],
    "output": {
      "blend": ".../scene_skeleton.blend",
      "fbx": ".../scene_skeleton.fbx",
      "layout": ".../layout.json"
    }
  }

产物：
  - .blend：完整场景（地面 + 参考图 + 体块 + 相机 + 灯光）
  - .fbx：只导出网格（地面 + 体块 + 参考图平面），供 Unity 导入
  - layout.json：阶段 5 的装配契约，手写坐标已转换到 Unity 空间（Y-up），
    字段说明见 dsh-scene-skeleton-pipeline/lib/layout.js 顶部注释。

脚本只依赖 Blender 自带的 bpy，退出码 0 表示成功。
"""

import hashlib
import json
import math
import os
import sys
import traceback

import bpy
from mathutils import Vector


def log(message):
    print("[dsh-blender] " + str(message), flush=True)


def read_spec():
    argv = sys.argv
    if "--" not in argv:
        raise RuntimeError("缺少 spec.json 参数（用法：--python build_scene.py -- spec.json）")
    spec_path = argv[argv.index("--") + 1]
    with open(spec_path, "r", encoding="utf-8") as handle:
        return json.load(handle), spec_path


def ensure_parent(path):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)


def make_principled_material(name, color, roughness=0.8):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    bsdf = nodes.get("Principled BSDF")
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
        bsdf.inputs["Roughness"].default_value = roughness
    return material


# Blender 是 Z-up、右手系；Unity 是 Y-up、左手系。位置/缩放按 (x, z, -y) 映射，
# 旋转用 M * R * M^T 换算（M 为正交矩阵，M^T 即 M 的逆）。
UNITY_BASIS = (
    (1.0, 0.0, 0.0),
    (0.0, 0.0, 1.0),
    (0.0, -1.0, 0.0),
)


def _num(value):
    """输出干净的数字：去掉浮点噪声与 -0.0。"""
    number = round(float(value), 4)
    return 0.0 if abs(number) < 1e-6 else number


def to_unity_point(value):
    """Blender 位置/朝向向量 → Unity 空间（Y-up）。"""
    return [_num(value.x), _num(value.z), _num(-value.y)]


def to_unity_scale(value):
    """Blender 缩放 → Unity 缩放（轴交换后 y/z 对调）。"""
    return [_num(value.x), _num(value.z), _num(value.y)]


def to_unity_euler(rotation_euler):
    """Blender Euler（弧度）→ Unity Euler（度，ZXY 顺序，与 Quaternion.Euler 一致）。"""
    matrix = rotation_euler.to_matrix()
    basis = matrix.__class__((UNITY_BASIS[0], UNITY_BASIS[1], UNITY_BASIS[2]))
    converted = basis @ matrix @ basis.transposed()
    euler = converted.to_euler("ZXY")
    return [_num(math.degrees(euler.x)), _num(math.degrees(euler.y)), _num(math.degrees(euler.z))]


def to_unity_direction(vector):
    """Blender 方向向量 → Unity 方向（Y-up）。"""
    return Vector((vector.x, vector.z, -vector.y)).normalized()


def directional_rotation(sun):
    """由 Blender 太阳灯的朝向推出 Unity 方向光 Euler 角度（pitch, yaw, 0）。

    Unity 方向光沿自身 forward 照射，forward = (sin(yaw)cos(pitch), -sin(pitch), cos(yaw)cos(pitch))。
    """
    direction = to_unity_direction(sun.matrix_world.to_3x3() @ Vector((0.0, 0.0, -1.0)))
    pitch = math.degrees(math.asin(max(-1.0, min(1.0, -direction.y))))
    yaw = math.degrees(math.atan2(direction.x, direction.z))
    return [_num(pitch), _num(yaw), 0.0]


def make_layout_object(obj, asset_name):
    """单个可装配对象：名字 + 已转换到 Unity 空间的位置/旋转/缩放。

    scale 是**实例额外缩放**（相对资产自身变换），不是物体原始 scale：导出前会把
    物体缩放烘进几何（bake_mesh_transforms），所以生成出来的 layout 恒为 [1, 1, 1]。
    Unity 侧按 localScale *= layout.scale 应用，既不会丢掉 fbx 自身的单位换算
    （cm→m 的 100 倍），也允许手工改 layout 做实例缩放。
    """
    return {
        "asset": asset_name,
        "instanceName": obj.name,
        "position": to_unity_point(obj.location),
        "rotation": to_unity_euler(obj.rotation_euler),
        "scale": to_unity_scale(obj.scale),
    }


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    world = bpy.data.worlds.new("DSHWorld")
    world.use_nodes = True
    background = world.node_tree.nodes.get("Background")
    if background is not None:
        background.inputs["Color"].default_value = (0.05, 0.06, 0.08, 1.0)
        background.inputs["Strength"].default_value = 1.0
    scene.world = world


def build_ground():
    bpy.ops.mesh.primitive_plane_add(size=40.0, location=(0.0, 0.0, 0.0))
    ground = bpy.context.object
    ground.name = "Ground"
    ground.data.materials.append(make_principled_material("GroundMat", (0.16, 0.17, 0.18), 0.95))
    return ground


def build_reference_planes(images):
    planes = []
    for index, image_path in enumerate(images):
        if not isinstance(image_path, str) or not os.path.isfile(image_path):
            log("跳过不存在的参考图：" + str(image_path))
            continue
        try:
            image = bpy.data.images.load(image_path, check_existing=True)
        except Exception as error:  # noqa: BLE001 - 单张参考图失败不影响骨架
            log("加载参考图失败：" + str(error))
            continue
        width, height = image.size
        aspect = (float(width) / float(height)) if height else 1.5
        plane_height = 8.0
        plane_width = plane_height * aspect

        bpy.ops.mesh.primitive_plane_add(
            size=1.0,
            location=(0.0, 10.0 + index * 0.2, plane_height / 2.0 + 0.02),
        )
        plane = bpy.context.object
        plane.name = "Reference_%d" % (index + 1)
        # 平面默认就在 XY 平面内（竖直、朝向 ±Z），保持不旋转才是竖立的参考图；
        # 之前绕 X 轴转 90° 会把它放平成一个悬空的天花板。
        plane.rotation_euler = (0.0, 0.0, 0.0)
        plane.scale = (plane_width, plane_height, 1.0)

        material = bpy.data.materials.new("ReferenceMat_%d" % (index + 1))
        material.use_nodes = True
        nodes = material.node_tree.nodes
        links = material.node_tree.links
        nodes.clear()
        output = nodes.new("ShaderNodeOutputMaterial")
        emission = nodes.new("ShaderNodeEmission")
        texture = nodes.new("ShaderNodeTexImage")
        texture.image = image
        links.new(texture.outputs["Color"], emission.inputs["Color"])
        links.new(emission.outputs["Emission"], output.inputs["Surface"])
        plane.data.materials.append(material)
        # 把旋转/缩放烘进网格：Unity 侧按 layout 只设置位置即可，避免轴变换带来的旋转误差。
        bpy.context.view_layer.objects.active = plane
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
        planes.append(plane)
        log("参考图平面：%s（%.1f x %.1f）" % (os.path.basename(image_path), plane_width, plane_height))
    return planes


def prompt_hash(prompt):
    digest = hashlib.sha256(str(prompt).encode("utf-8")).hexdigest()
    return int(digest[:12], 16)


def build_massing(prompt):
    """根据 prompt 的哈希生成确定但不可预料的体块布局（场景骨架）。"""
    seed = prompt_hash(prompt)
    blocks = []
    layout = [
        (-6.0, -4.0, 3.2),
        (5.5, -4.5, 2.6),
        (-5.5, 4.0, 2.2),
        (5.0, 4.5, 3.6),
        (0.0, 0.0, 0.0),
    ]
    names = ["Massing_A", "Massing_B", "Massing_C", "Massing_D"]
    for index, (base_x, base_y, base_height) in enumerate(layout):
        if index == 4:
            # 中间留一个低矮的铺地台基，像庭院的地坪。
            bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.0, 0.0, 0.1))
            slab = bpy.context.object
            slab.name = "Courtyard_Slab"
            slab.scale = (11.0, 8.0, 0.2)
            slab.data.materials.append(make_principled_material("SlabMat", (0.30, 0.29, 0.26), 0.9))
            blocks.append(slab)
            continue
        size_x = 2.4 + ((seed >> (index * 5)) & 7) * 0.35
        size_y = 2.0 + ((seed >> (index * 5 + 3)) & 7) * 0.3
        height = max(1.6, base_height + (((seed >> (index * 7)) & 3) - 1) * 0.8)
        bpy.ops.mesh.primitive_cube_add(
            size=1.0,
            location=(base_x, base_y, height / 2.0),
        )
        block = bpy.context.object
        block.name = names[index]
        block.scale = (size_x, size_y, height)
        tone = 0.42 + ((seed >> (index * 3)) & 3) * 0.05
        block.data.materials.append(
            make_principled_material("MassingMat_%d" % (index + 1), (tone, tone * 0.96, tone * 0.9), 0.85)
        )
        blocks.append(block)
        log("体块 %s：位置(%.1f, %.1f) 尺寸(%.1f x %.1f x %.1f)" % (names[index], base_x, base_y, size_x, size_y, height))
    return blocks


def build_camera_and_light():
    target = bpy.data.objects.new("CameraTarget", None)
    bpy.context.scene.collection.objects.link(target)
    target.location = (0.0, 0.0, 2.5)

    camera_data = bpy.data.cameras.new("SceneCamera")
    camera_data.lens = 45.0
    camera = bpy.data.objects.new("SceneCamera", camera_data)
    bpy.context.scene.collection.objects.link(camera)
    camera.location = (15.0, -15.0, 12.0)
    constraint = camera.constraints.new(type="TRACK_TO")
    constraint.target = target
    constraint.track_axis = "TRACK_NEGATIVE_Z"
    constraint.up_axis = "UP_Y"
    bpy.context.scene.camera = camera

    sun_data = bpy.data.lights.new("SunLight", type="SUN")
    sun_data.energy = 4.0
    sun = bpy.data.objects.new("SunLight", sun_data)
    bpy.context.scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(52.0), 0.0, math.radians(35.0))

    fill_data = bpy.data.lights.new("FillLight", type="AREA")
    fill_data.energy = 400.0
    fill_data.size = 12.0
    fill = bpy.data.objects.new("FillLight", fill_data)
    bpy.context.scene.collection.objects.link(fill)
    fill.location = (-10.0, -8.0, 10.0)
    fill.rotation_euler = (math.radians(55.0), 0.0, math.radians(-125.0))
    return {"camera": camera, "sun": sun, "target": target}


def bake_mesh_transforms(mesh_objects):
    """把物体缩放烘进网格数据，避免 Unity 侧覆盖 localScale 时丢掉 fbx 的单位换算。

    Blender 导出的 fbx 节点 localScale 已经带了 100 倍的单位换算（cm/m）。如果 Unity 侧
    直接把 layout.scale 赋给 localScale，几何就会小 100 倍。把物体自身 scale 烘进网格后，
    节点上只剩单位换算，layout.scale 才是纯“实例额外缩放”。
    """
    for obj in mesh_objects:
        if obj is None or obj.name not in bpy.data.objects:
            continue
        if obj.type != "MESH":
            continue
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)


def export_outputs(spec, mesh_objects):
    output = spec.get("output") if isinstance(spec.get("output"), dict) else {}
    blend_path = output.get("blend") or ""
    fbx_path = output.get("fbx") or ""
    if blend_path == "" or fbx_path == "":
        raise RuntimeError("spec.output 必须同时包含 blend 与 fbx 路径")
    ensure_parent(blend_path)
    ensure_parent(fbx_path)

    bake_mesh_transforms(mesh_objects)

    bpy.ops.wm.save_as_mainfile(filepath=blend_path)
    log("已保存 .blend：" + blend_path)

    bpy.ops.object.select_all(action="DESELECT")
    selected = 0
    for obj in mesh_objects:
        if obj is not None and obj.name in bpy.data.objects:
            obj.select_set(True)
            selected += 1
    if selected == 0:
        raise RuntimeError("没有可导出的网格对象")

    bpy.ops.export_scene.fbx(filepath=fbx_path, use_selection=True, apply_unit_scale=True)
    log("已导出 .fbx：" + fbx_path)
    return {"blend": blend_path, "fbx": fbx_path, "meshes": [obj.name for obj in mesh_objects if obj is not None]}


def export_layout(spec, groups, camera_rig):
    """写出 layout.json（阶段 5 装配契约，字段见 lib/layout.js 顶部注释）。"""
    output = spec.get("output") if isinstance(spec.get("output"), dict) else {}
    layout_path = output.get("layout") or ""
    if layout_path == "":
        log("spec.output.layout 为空，跳过 layout.json")
        return None

    fbx_name = os.path.basename(str(output.get("fbx") or "scene_skeleton.fbx")) or "scene_skeleton.fbx"
    scene_name = str(spec.get("scene_name") or "SceneSkeleton")
    payload = {
        "sceneName": scene_name,
        "root": "SceneSkeleton_Root",
        "groups": [
            {
                "name": name,
                "objects": [make_layout_object(obj, fbx_name) for obj in objects if obj is not None],
            }
            for name, objects in groups.items()
            if objects
        ],
        "lighting": {
            "ambient": {"intensity": 0.4, "color": [1.0, 1.0, 1.0]},
            "directional": {
                "intensity": 1.0,
                "rotation": directional_rotation(camera_rig["sun"]),
                "color": [1.0, 1.0, 1.0],
            },
            "skybox": "default",
        },
        "camera": {
            "position": to_unity_point(camera_rig["camera"].location),
            "lookAt": to_unity_point(camera_rig["target"].location),
        },
        "prefab": {"enabled": False, "path": "Assets/Prefabs/"},
    }

    ensure_parent(layout_path)
    with open(layout_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
    total = sum(len(group["objects"]) for group in payload["groups"])
    log("已写出 layout.json：%s（%d 个对象，分组：%s）" % (
        layout_path,
        total,
        ", ".join(group["name"] for group in payload["groups"]),
    ))
    return layout_path


def main():
    spec, spec_path = read_spec()
    log("读取 spec：" + spec_path)
    if not os.path.isdir(os.path.dirname(os.path.abspath(spec_path))):
        raise RuntimeError("spec 所在目录不存在")

    reset_scene()
    ground = build_ground()
    massing_objects = build_massing(spec.get("prompt") or "")
    reference_planes = build_reference_planes(spec.get("images") or [])
    mesh_objects = [ground, *massing_objects, *reference_planes]
    camera_rig = build_camera_and_light()

    result = export_outputs(spec, mesh_objects)
    layout_path = export_layout(
        spec,
        {"Terrain": [ground], "Props": massing_objects, "Reference": reference_planes},
        camera_rig,
    )
    result["layout"] = layout_path
    result["groups"] = {
        "Terrain": [ground.name],
        "Props": [obj.name for obj in massing_objects],
        "Reference": [obj.name for obj in reference_planes],
    }
    result["scene"] = spec.get("title") or ""
    result["spec"] = spec_path
    print("DSH_BLENDER_RESULT:" + json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - 把 traceback 打印给调用方
        traceback.print_exc()
        print("DSH_BLENDER_ERROR:" + str(error), flush=True)
        sys.exit(1)
