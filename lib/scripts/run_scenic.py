"""scenic 模式的 Blender 运行器（在 Blender 自带 Python 里运行）。

把 scenic spec（lib/scripts/scenes/*.py）编译成 Blender 场景，在 Blender 内建好
Empty 层级（root + 语义分组）、配置光照 / 世界背景 / 相机，然后一次性导出四个产物：

    scene.blend      装配后的完整场景（层级 + 光照 + 相机 + 世界背景）
    scene.fbx       引擎就绪骨架（保留 Empty 层级，供 Unity 等按名字装配）
    scene.glb       引擎无关备份（glTF 规范 Y-up，与 .blend/.fbx 的 Z-up 并存）
    layout.json     布局契约（root / groups / objects / lighting / camera）

调用（位置参数在 `--` 之后，Blender 会抢 `--flag`，所以只用位置参数）：

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python <本文件> -- <spec.py> <out.blend> <out.glb> <out.fbx> <out/layout.json> '<params-json>'

layout.json 与 legacy 模式（build_scene.py）同一份契约，坐标由 layoutAxis 决定：
z-up（默认）写 Blender 原生 Z-up 坐标；y-up 写 Unity Y-up 转换值（位置 (x, z, -y)；旋转 M*R*Mᵀ）。
layout.json 顶层带 "axis" 字段标明坐标系，
对象名取 spec 里 .named() 的实例名，分组名取顶层 Group 空节点的名字。
Unity 2022.3 没有内置 glTF 导入器（.glb 会被当 DefaultAsset），所以 Unity 装配用 .fbx，
layout.json 的 asset 字段固定为 scene_skeleton.fbx；.glb 作为引擎就绪产物一并输出。

FBX 导出用 use_selection=False（全场景）+ object_types 含 EMPTY/LIGHT/CAMERA，
这样 SceneSkeleton_Root / Terrain / Buildings / Props 这些 Empty 分组节点会被保留；
bake_space_transform=False 避免坐标系被二次烘焙（引擎导入器自行处理 Z-up→Y-up）。
编译成功打印 `DSH_BLENDER_RESULT:<json>`，失败打印 `DSH_BLENDER_ERROR:<msg>` 并 exit 1。
"""
import argparse
import importlib.util
import json
import math
import os
import sys
from pathlib import Path

# Blender 的内嵌解释器不读 PYTHONPATH；scenic-bpy 通过 `pip install --user scenic-bpy`
# 装到用户 site-packages，这里手动把它加进 sys.path，spec 里的 `from scenic import ...` 才能解析。
_USER_SITE = os.path.expanduser("~/.local/lib/python3.11/site-packages")
if os.path.isdir(_USER_SITE) and _USER_SITE not in sys.path:
    sys.path.insert(0, _USER_SITE)

# 同目录的纯 Python 校验模块（不依赖 bpy），llm 模式在 Blender 内复用同一套规则。
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from layout_validate import load_plan, validate_plan  # noqa: E402

import bpy
from mathutils import Euler, Matrix, Vector

# Blender 是 Z-up、右手系；Unity 是 Y-up、左手系（与 build_scene.py 相同的换算）。
UNITY_BASIS = (
    (1.0, 0.0, 0.0),
    (0.0, 0.0, 1.0),
    (0.0, -1.0, 0.0),
)
SCENE_NAME = "ScenicCourtyard"
ROOT_NAME = f"{SCENE_NAME}_Root"
ASSET_NAME = "scene_skeleton.fbx"
CAMERA_NAME = "SceneSkeleton_Camera"
SUN_NAME = "SceneSkeleton_Sun"
AMBIENT_DEFAULT = {"intensity": 0.4, "color": [1.0, 1.0, 1.0]}
# 中性灰蓝天际色（世界背景），强度 1.0；layout.skybox="default" 表示「有世界背景」。
WORLD_COLOR = (0.45, 0.52, 0.60, 1.0)
WORLD_STRENGTH = 1.0


def num(value):
    number = round(float(value), 4)
    return 0.0 if abs(number) < 1e-6 else number


def vec(values):
    return [num(values[0]), num(values[1]), num(values[2])]


def to_unity_point(loc):
    return [num(loc[0]), num(loc[2]), num(-loc[1])]


def to_unity_scale(scale):
    return [num(scale[0]), num(scale[2]), num(scale[1])]


def to_unity_euler(degrees_euler):
    """scenic ObjectSpec.rotation 是 Euler XYZ 度 → Unity Euler 度（ZXY，Quaternion.Euler 一致）。"""
    matrix = Euler((math.radians(degrees_euler[0]), math.radians(degrees_euler[1]), math.radians(degrees_euler[2])), "XYZ").to_matrix()
    basis = Matrix(UNITY_BASIS)
    converted = basis @ matrix @ basis.transposed()
    euler = converted.to_euler("ZXY")
    return [num(math.degrees(euler.x)), num(math.degrees(euler.y)), num(math.degrees(euler.z))]


def to_unity_direction(vector):
    return Vector((vector.x, vector.z, -vector.y)).normalized()


def directional_rotation(rotation_degrees):
    """SunSpec.rotation（Euler XYZ 度）→ Unity 方向光 Euler（pitch, yaw, 0）。"""
    matrix = Euler((math.radians(rotation_degrees[0]), math.radians(rotation_degrees[1]), math.radians(rotation_degrees[2])), "XYZ").to_matrix()
    direction = to_unity_direction(matrix @ Vector((0.0, 0.0, -1.0)))
    pitch = math.degrees(math.asin(max(-1.0, min(1.0, -direction.y))))
    yaw = math.degrees(math.atan2(direction.x, direction.z))
    return [num(pitch), num(yaw), 0.0]


# ---------------------------------------------------------------------------
# layout 坐标系（layoutAxis 配置：'z-up' 写 Blender 原生坐标，'y-up' 写 Unity 转换值）
# ---------------------------------------------------------------------------
LAYOUT_AXES = ("z-up", "y-up")


def layout_point(blender_point, axis):
    """Blender 坐标 → layout 坐标（axis='y-up' 时转 Unity Y-up）。"""
    if axis == "z-up":
        return [num(blender_point[0]), num(blender_point[1]), num(blender_point[2])]
    return to_unity_point(blender_point)


def layout_euler(blender_rotation_degrees, axis):
    """Blender Euler XYZ 度 → layout 旋转（axis='y-up' 时转 Unity ZXY 度）。"""
    if axis == "z-up":
        return [num(value) for value in blender_rotation_degrees]
    return to_unity_euler(blender_rotation_degrees)


def layout_directional(sun_rotation_degrees, axis):
    """太阳光 rotation → layout lighting.directional.rotation。"""
    if axis == "z-up":
        return [num(value) for value in sun_rotation_degrees]
    return directional_rotation(sun_rotation_degrees)


def blender_point_from_layout(point, axis):
    """layout 坐标 → Blender 坐标（'y-up': b=(x,-z,y)；'z-up': 原样）。"""
    if axis == "z-up":
        return (float(point[0]), float(point[1]), float(point[2]))
    return (float(point[0]), -float(point[2]), float(point[1]))


def _walk_group_objects(group_spec, objects, axis, depth=0):
    """把一个分组里的对象展平成 layout objects（不递归进具名装配体内部）。"""
    for child in group_spec.children:
        has_geometry = getattr(child, "geometry", None) is not None
        if getattr(child, "name", None):
            # 具名节点 = 可装配实例（柱子/墙/树……），Unity 按 instanceName 找 fbx 内同名节点
            objects.append(
                {
                    "asset": ASSET_NAME,
                    "instanceName": child.name,
                    "position": layout_point(child.location, axis),
                    "rotation": layout_euler(child.rotation, axis),
                    # scenic 导出的 fbx 节点自带真实缩放（未烘焙），Unity 装配时会保留
                    # 节点自身的 world 缩放；layout.scale 是「实例额外缩放」，恒为 1，
                    # 避免 Unity 端把同一缩放应用两次（曾导致 plaza/wall 尺寸错乱）。
                    "scale": [1.0, 1.0, 1.0],
                }
            )
            continue
        if not has_geometry and depth < 4:
            # 匿名空节点（透明包装）→ 继续向下找具名节点
            _walk_group_objects(child, objects, axis, depth + 1)
        # 匿名网格：属于某个装配体内部，Unity 侧随父节点一起移动，不进 layout


def build_layout(scene_spec, axis):
    groups = []
    for top in scene_spec.objects:
        if not getattr(top, "name", None):
            continue
        objects = []
        _walk_group_objects(top, objects, axis)
        groups.append({"name": top.name, "objects": objects})

    suns = [light for light in scene_spec.lights if getattr(light, "kind", "") == "sun"]
    # 强度/颜色/角度都从第一个太阳光读取（角度转成 Unity 方向光 pitch/yaw）。
    directional = {
        "intensity": num(suns[0].energy) if suns else 3.0,
        "rotation": layout_directional(suns[0].rotation, axis) if suns else [50.0, -30.0, 0.0],
        "color": [1.0, 1.0, 1.0],
        "name": SUN_NAME,
    }
    if suns:
        color = suns[0].color
        directional["color"] = [num(color[0]), num(color[1]), num(color[2])]

    camera = scene_spec.camera
    camera_section = {
        "position": [10.0, 8.0, 10.0],
        "lookAt": [0.0, 0.0, 0.0],
        "name": CAMERA_NAME,
    }
    if camera is not None:
        camera_section["position"] = layout_point(camera.location, axis)
        if camera.look_at is not None:
            camera_section["lookAt"] = layout_point(camera.look_at, axis)

    return {
        "sceneName": SCENE_NAME,
        "root": ROOT_NAME,
        "axis": axis,
        "groups": groups,
        "lighting": {
            "ambient": dict(AMBIENT_DEFAULT),
            "directional": directional,
            "skybox": "default" if scene_spec.world is not None else None,
        },
        "camera": camera_section,
        "prefab": {"enabled": False, "path": "Assets/Prefabs/"},
    }


def load_app(spec_path):
    path = Path(spec_path).expanduser().resolve()
    if not path.exists():
        raise RuntimeError(f"spec 文件不存在：{path}")
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))
    module_spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    apps = [value for value in vars(module).values() if value.__class__.__name__ == "Scenic"]
    if not apps:
        raise RuntimeError(f"{path.name} 里没有 Scenic app（需要 app = Scenic(...)）")
    return apps[0]


def parent_keep_transform(child, parent):
    """把 child 挂到 parent 下，保持世界变换不变。"""
    world = child.matrix_world.copy()
    child.parent = parent
    child.matrix_parent_inverse = parent.matrix_world.inverted()
    child.matrix_world = world


def assemble_hierarchy(layout):
    """在编译后的场景里建 root Empty，并把分组 Empty 挂到 root 下（世界变换不变）。"""
    root_name = layout["root"]
    root = bpy.data.objects.get(root_name)
    if root is None:
        root = bpy.data.objects.new(root_name, None)
        bpy.context.scene.collection.objects.link(root)
    root.location = (0.0, 0.0, 0.0)
    root.rotation_euler = (0.0, 0.0, 0.0)
    root.scale = (1.0, 1.0, 1.0)
    for group in layout["groups"]:
        child = bpy.data.objects.get(group["name"])
        if child is None or child == root:
            continue
        parent_keep_transform(child, root)


def configure_camera(layout, axis):
    """复用/创建相机，按 layout 的 position/lookAt 设位置与朝向（相机 -Z 指向目标）。"""
    camera = next((obj for obj in bpy.data.objects if obj.type == "CAMERA"), None)
    if camera is None:
        bpy.ops.object.camera_add()
        camera = bpy.context.active_object
    camera.name = CAMERA_NAME
    camera.constraints.clear()
    position = blender_point_from_layout(layout["camera"]["position"], axis)
    look_at = blender_point_from_layout(layout["camera"]["lookAt"], axis)
    camera.location = Vector(position)
    direction = Vector(look_at) - camera.location
    if direction.length > 1e-6:
        camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = camera
    return camera


def _unity_directional_to_blender(rotation_degrees):
    """Unity 方向光 Euler（pitch, yaw, 0）→ Blender 里的光线方向向量（单位、Z-up）。"""
    pitch = math.radians(float(rotation_degrees[0]))
    yaw = math.radians(float(rotation_degrees[1]))
    direction = Vector((math.sin(yaw) * math.cos(pitch), -math.sin(pitch), math.cos(yaw) * math.cos(pitch)))
    # Unity→Blender 与点/缩放同一套换算：b = (u_x, -u_z, u_y)
    return Vector((direction.x, -direction.z, direction.y)).normalized()


def configure_lights(layout, axis):
    """命名太阳光，并把强度/颜色/角度与 layout 对齐（layout 是唯一事实来源）。"""
    suns = [obj for obj in bpy.data.objects if obj.type == "LIGHT" and obj.data.type == "SUN"]
    for index, sun in enumerate(suns):
        sun.name = SUN_NAME if index == 0 else f"{SUN_NAME}_Fill{index}"
    if not suns:
        bpy.ops.object.light_add(type="SUN")
        sun = bpy.context.active_object
        sun.name = SUN_NAME
        suns = [sun]
    directional = layout["lighting"]["directional"]
    suns[0].data.energy = float(directional.get("intensity", 3.0))
    color = directional.get("color", [1.0, 1.0, 1.0])
    suns[0].data.color = (float(color[0]), float(color[1]), float(color[2]))
    rotation = directional.get("rotation") or [50.0, -30.0, 0.0]
    if axis == "z-up":
        # z-up：layout 里就是 Blender 原生欧拉角
        suns[0].rotation_euler = Euler(tuple(math.radians(float(value)) for value in rotation), "XYZ")
    else:
        blender_direction = _unity_directional_to_blender(rotation)
        if blender_direction.length > 1e-6:
            suns[0].rotation_euler = blender_direction.to_track_quat("-Z", "Y").to_euler()
    return suns


def configure_world():
    """确保世界有 Background 节点，给中性灰蓝天际色。"""
    world = bpy.context.scene.world
    if world is None:
        world = bpy.data.worlds.new("World")
        bpy.context.scene.world = world
    world.use_nodes = True
    tree = world.node_tree
    bg = tree.nodes.get("Background")
    if bg is None:
        bg = tree.nodes.new(type="ShaderNodeBackground")
    world_output = tree.nodes.get("World Output")
    if world_output is None:
        world_output = tree.nodes.new(type="ShaderNodeOutputWorld")
    tree.links.new(bg.outputs["Background"], world_output.inputs["Surface"])
    bg.inputs["Color"].default_value = WORLD_COLOR
    bg.inputs["Strength"].default_value = WORLD_STRENGTH
    return world


# ---------------------------------------------------------------------------
# llm 模式：按 plan（精确布局 JSON）程序化建几何
# ---------------------------------------------------------------------------

LLM_SCENE_NAME = "LLMScene"
DEFAULT_PLAN_BOUNDS = {"width": 24.0, "depth": 20.0}

# 语义资产库（唯一事实源）：type 白名单 + 尺寸范围 + 程序化几何。
# 新增 type 只需改 lib/asset-library.json，并在 _build_geometry_part 支持它的 shape。
ASSET_LIBRARY_PATH = Path(__file__).resolve().parent.parent / "asset-library.json"
with open(ASSET_LIBRARY_PATH, "r", encoding="utf-8") as _library_handle:
    ASSET_LIBRARY = json.load(_library_handle)
ASSET_BY_TYPE = {entry["type"]: entry for entry in ASSET_LIBRARY["assets"]}
PLAN_GROUP_BY_TYPE = {entry["type"]: entry["category"] for entry in ASSET_LIBRARY["assets"]}
LLM_MATERIALS = {
    key: (tuple(float(channel) for channel in spec["color"]), float(spec["roughness"]))
    for key, spec in ASSET_LIBRARY["materials"].items()
}


def _unity_to_blender_point(point):
    """Unity Y-up 坐标 → Blender Z-up 坐标（b = (u_x, -u_z, u_y)）。"""
    return (float(point[0]), -float(point[2]), float(point[1]))


def blender_euler_from_unity(degrees):
    """Unity Euler（Quaternion.Euler 的 ZXY 顺序、度）→ Blender XYZ 弧度。"""
    matrix = Euler(tuple(math.radians(float(value)) for value in degrees), "ZXY").to_matrix()
    basis = Matrix(UNITY_BASIS)
    converted = basis.transposed() @ matrix @ basis
    euler = converted.to_euler("XYZ")
    return (euler.x, euler.y, euler.z)


# 材质映射（块 D）：asset-library.json 里每个材质 key 可选 albedo/normal/roughness/metallic 贴图，
# 路径相对 assetLibraryPath 配置。贴图存在时创建带 Image Texture 的 Principled BSDF；
# 未配置或文件缺失时回退到「纯色 + 粗糙度」常量（即块 C 之前的行为）。
MATERIAL_TEXTURE_ROOT = None
MATERIAL_TEXTURE_SPECS = {
    key: dict(spec) for key, spec in ASSET_LIBRARY["materials"].items()
}
MATERIAL_USAGE = {}
MATERIAL_MAPPING_INFO = {
    "enabled": False,
    "assetLibraryPath": "",
    "keysWithTextures": [],
    "keysFallback": [],
}


def configure_material_mapping(mapping_config):
    """配置材质贴图根目录；返回给 summary 的结构化状态。"""
    global MATERIAL_TEXTURE_ROOT, MATERIAL_USAGE
    MATERIAL_USAGE = {}
    root_value = ""
    if isinstance(mapping_config, dict):
        root_value = str(mapping_config.get("assetLibraryPath") or "").strip()
    MATERIAL_TEXTURE_ROOT = Path(root_value).expanduser().resolve() if root_value else None
    MATERIAL_MAPPING_INFO.clear()
    MATERIAL_MAPPING_INFO.update(
        {
            "enabled": MATERIAL_TEXTURE_ROOT is not None,
            "assetLibraryPath": str(MATERIAL_TEXTURE_ROOT) if MATERIAL_TEXTURE_ROOT else "",
            "keysWithTextures": [],
            "keysFallback": [],
        }
    )
    return MATERIAL_MAPPING_INFO


def _material_texture_paths(key):
    """该材质 key 下实际存在的贴图文件路径（albedo/normal/roughness/metallic）。"""
    spec = MATERIAL_TEXTURE_SPECS.get(key) or {}
    found = {}
    if MATERIAL_TEXTURE_ROOT is None:
        return found
    for slot in ("albedo", "normal", "roughness", "metallic"):
        relative = str(spec.get(f"{slot}Path") or "").strip()
        if not relative:
            continue
        candidate = Path(relative)
        if not candidate.is_absolute():
            candidate = MATERIAL_TEXTURE_ROOT / candidate
        candidate = candidate.expanduser()
        if candidate.is_file():
            found[slot] = candidate
    return found


def _material_image_node(material, path, colorspace):
    """创建 Image Texture 节点（同路径复用 bpy.data.images）。"""
    image = bpy.data.images.load(str(path), check_existing=True)
    try:
        image.colorspace_settings.name = colorspace
    except Exception:  # noqa: BLE001 —— 某些格式不允许改 colorspace，保持默认
        pass
    node = material.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = image
    node.label = path.name
    return node


def _material(key):
    """按 key 取共享材质：配置了贴图走材质映射，否则纯色回退。"""
    color, roughness = LLM_MATERIALS.get(key, LLM_MATERIALS["stone"])
    name = f"LLM_{key}"
    material = bpy.data.materials.get(name)
    if material is not None:
        return material

    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    if bsdf is None:
        return material

    textures = _material_texture_paths(key)
    source = "library" if "albedo" in textures else "fallback"

    # Base Color：albedo 贴图优先，否则纯色
    if "albedo" in textures:
        albedo_node = _material_image_node(material, textures["albedo"], "sRGB")
        links.new(albedo_node.outputs["Color"], bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = (*color, 1.0)

    # Roughness / Metallic：贴图优先，否则常量
    if "roughness" in textures:
        roughness_node = _material_image_node(material, textures["roughness"], "Non-Color")
        links.new(roughness_node.outputs["Color"], bsdf.inputs["Roughness"])
    else:
        bsdf.inputs["Roughness"].default_value = roughness

    if "metallic" in textures:
        metallic_node = _material_image_node(material, textures["metallic"], "Non-Color")
        links.new(metallic_node.outputs["Color"], bsdf.inputs["Metallic"])

    # Normal：Non-Color Image Texture → Normal Map → Normal
    if "normal" in textures:
        normal_node = _material_image_node(material, textures["normal"], "Non-Color")
        normal_map = nodes.new("ShaderNodeNormalMap")
        links.new(normal_node.outputs["Color"], normal_map.inputs["Color"])
        links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])

    material["material_source"] = source
    material["material_key"] = key
    MATERIAL_USAGE[key] = source
    if source == "library":
        MATERIAL_MAPPING_INFO["keysWithTextures"].append(key)
    else:
        MATERIAL_MAPPING_INFO["keysFallback"].append(key)
    return material


# 几何模型映射（块 E）：asset-library.json 里每个 type 可选 modelPath（相对 assetModelPath 的
# .glb/.gltf 路径）。存在则导入真实模型并「Join 合并 + 底部中心对齐原点 + 等比缩放（高度为主，
# 不暴力拉伸）」；不存在则回退到上面的程序化图元。
MODEL_ROOT = None
GEOMETRY_MAPPING_INFO = {"modelsUsed": 0, "primitivesFallback": 0}


def configure_model_mapping(mapping_config):
    """配置真实模型根目录。"""
    global MODEL_ROOT
    root_value = ""
    if isinstance(mapping_config, dict):
        root_value = str(mapping_config.get("assetModelPath") or "").strip()
    MODEL_ROOT = Path(root_value).expanduser().resolve() if root_value else None
    GEOMETRY_MAPPING_INFO["modelsUsed"] = 0
    GEOMETRY_MAPPING_INFO["primitivesFallback"] = 0


def _resolve_model_path(entry):
    """该 type 的真实模型文件路径；不存在返回 None。"""
    relative = str(entry.get("modelPath") or "").strip()
    if not relative or MODEL_ROOT is None:
        return None
    candidate = Path(relative)
    if not candidate.is_absolute():
        candidate = MODEL_ROOT / candidate
    candidate = candidate.expanduser()
    return candidate if candidate.is_file() else None


def _world_bbox(obj):
    corners = [obj.matrix_world @ Vector(tuple(corner)) for corner in obj.bound_box]
    xs = [corner.x for corner in corners]
    ys = [corner.y for corner in corners]
    zs = [corner.z for corner in corners]
    return (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs))


def _import_model_gltf(path):
    """用 Blender 内置 glTF 导入器导入模型，返回新增的对象列表。"""
    before = set(bpy.data.objects)
    try:
        bpy.ops.import_scene.gltf(filepath=str(path))
    except Exception as error:  # noqa: BLE001
        print(f"[geometry] 导入模型失败 {path}：{error}", file=sys.stderr)
        return []
    return [obj for obj in bpy.data.objects if obj not in before]


def _join_model_meshes(imported):
    """把导入产生的所有 MESH join 成一个，删除无用 Empty/Light/Camera。返回主 mesh 或 None。"""
    meshes = [obj for obj in imported if obj.type == "MESH"]
    if not meshes:
        return None
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    if len(meshes) > 1:
        bpy.ops.object.join()
    main = bpy.context.view_layer.objects.active
    for obj in imported:
        if obj is not main and obj.name in bpy.data.objects:
            bpy.data.objects.remove(obj, do_unlink=True)
    return main


def _align_and_scale_model(mesh, sx, sy, sz):
    """底部中心对齐原点 + 等比缩放：高度为主，同时不超宽/超深（严禁暴力拉伸）。"""
    bpy.context.view_layer.objects.active = mesh
    mesh.select_set(True)
    # 先把导入带来的位置/旋转/缩放烘进几何，得到单位世界变换
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    minx, maxx, miny, maxy, minz, maxz = _world_bbox(mesh)
    width = maxx - minx
    depth = maxy - miny
    height = maxz - minz
    if height <= 1e-6:
        height = 1.0
    scale = sy / height
    if scale <= 1e-9:
        scale = 1.0
    mesh.scale = (scale, scale, scale)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # 现在几何已等比缩放，把底部中心平移到（局部）原点
    minx, maxx, miny, maxy, minz, maxz = _world_bbox(mesh)
    mesh.location.x -= (minx + maxx) / 2.0
    mesh.location.y -= (miny + maxy) / 2.0
    mesh.location.z -= minz
    return mesh


def _build_model_object(object_id, entry, base, sx, sy, sz):
    """尝试按 modelPath 导入真实模型并装配到 base 下；无模型时返回 None。"""
    path = _resolve_model_path(entry)
    if path is None:
        return None
    imported = _import_model_gltf(path)
    mesh = _join_model_meshes(imported)
    if mesh is None:
        for obj in imported:
            if obj.name in bpy.data.objects:
                bpy.data.objects.remove(obj, do_unlink=True)
        return None
    mesh.name = object_id
    _align_and_scale_model(mesh, sx, sy, sz)
    # 保留模型自带材质；完全没有材质槽时才回退 _material
    if not mesh.data.materials:
        parts = entry.get("geometry") or []
        material_key = str((parts[0].get("material") if parts else "") or "stone")
        mesh.data.materials.append(_material(material_key))
    _attach(mesh, base)
    mesh["asset_source"] = "model"
    return mesh


def _link(name, data=None):
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def _attach(obj, parent):
    """父节点在原点、单位变换，子节点用局部坐标（局部坐标系与 Blender 世界轴一致）。"""
    obj.parent = parent
    obj.matrix_parent_inverse = Matrix.Identity(4)


def _add_box(name, local_center_u, dims_u, material, parent):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.0, 0.0, 0.0))
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (float(dims_u[0]), float(dims_u[2]), float(dims_u[1]))
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    _attach(obj, parent)
    obj.location = Vector(_unity_to_blender_point(local_center_u))
    return obj


def _add_cylinder(name, local_center_u, radius, depth, material, parent, vertices=16):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=float(radius), depth=float(depth), location=(0.0, 0.0, 0.0))
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(material)
    _attach(obj, parent)
    obj.location = Vector(_unity_to_blender_point(local_center_u))
    return obj


def _add_cone(name, local_center_u, radius, depth, material, parent, vertices=16):
    bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=float(radius), radius2=0.0, depth=float(depth), location=(0.0, 0.0, 0.0))
    obj = bpy.context.active_object
    obj.name = name
    obj.data.materials.append(material)
    _attach(obj, parent)
    obj.location = Vector(_unity_to_blender_point(local_center_u))
    return obj


def _add_rock(name, local_center_u, dims_u, material, parent):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.5, location=(0.0, 0.0, 0.0))
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (float(dims_u[0]), float(dims_u[2]), float(dims_u[1]))
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    _attach(obj, parent)
    obj.location = Vector(_unity_to_blender_point(local_center_u))
    return obj


def _add_plane(name, width, depth, material, parent):
    bpy.ops.mesh.primitive_plane_add(size=1.0, location=(0.0, 0.0, 0.0))
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (float(width), float(depth), 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    _attach(obj, parent)
    return obj


def _clear_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)


def _local_center(sx, sy, sz, offset):
    """把「相对尺寸比例」的偏移换算成 Unity 局部坐标（米）。"""
    ox, oy, oz = (float(offset[0]), float(offset[1]), float(offset[2]))
    return (ox * sx, oy * sy, oz * sz)


def _build_geometry_part(part, object_id, index, sx, sy, sz, base):
    """按资产库里的 geometry 定义建一个图元（全部挂在同名 Empty 下）。"""
    shape = str(part.get("shape") or "box")
    material = _material(str(part.get("material") or "stone"))
    name = f"{object_id}_part{index + 1}"
    footprint = min(sx, sz)
    offset = part.get("offset") or [0.0, 0.5, 0.0]

    if shape == "box":
        size = part.get("size") or [1.0, 1.0, 1.0]
        dims = (float(size[0]) * sx, float(size[1]) * sy, float(size[2]) * sz)
        return _add_box(name, _local_center(sx, sy, sz, offset), dims, material, base)
    if shape in ("cylinder", "cone"):
        center = _local_center(sx, sy, sz, offset)
        radius = float(part.get("radius", 0.5)) * footprint / 2.0
        height = float(part.get("height", 1.0)) * sy
        add = _add_cylinder if shape == "cylinder" else _add_cone
        return add(name, center, radius, height, material, base, vertices=16 if shape == "cylinder" else 12)
    if shape == "sphere":
        center = _local_center(sx, sy, sz, offset)
        radius = float(part.get("radius", 0.5)) * footprint / 2.0
        return _add_rock(name, center, (radius * 2.0, radius * 2.0, radius * 2.0), material, base)
    if shape == "blob":
        size = part.get("size") or [1.0, 1.0, 1.0]
        dims = (float(size[0]) * sx, float(size[1]) * sy, float(size[2]) * sz)
        return _add_rock(name, _local_center(sx, sy, sz, offset), dims, material, base)
    if shape == "steps":
        count = max(1, int(part.get("count", 5)))
        direction = str(part.get("direction") or "z")
        created = []
        for step in range(count):
            ratio = (step + 1) / count
            if direction == "x":
                dims = (sx / count, sy * ratio, sz)
                center = (-sx / 2.0 + (step + 0.5) * sx / count, sy * ratio / 2.0, 0.0)
            else:
                dims = (sx, sy * ratio, sz / count)
                center = (0.0, sy * ratio / 2.0, -sz / 2.0 + (step + 0.5) * sz / count)
            created.append(_add_box(f"{object_id}_step{step + 1}", center, dims, material, base))
        return created
    raise RuntimeError(f"资产库里的未知几何 shape：{shape}（type={object_id}）")


def _build_plan_object(spec, group):
    """按 plan 对象 + 资产库几何建「同名 Empty + 图元子节点」。Empty 在底面中心。"""
    object_id = spec["id"]
    type_ = spec["type"]
    entry = ASSET_BY_TYPE.get(type_)
    if entry is None:  # pragma: no cover —— validate_layout 已经在前面拦住未知类型
        raise RuntimeError(f"未知的 plan 对象类型：{type_}")
    position = spec["position"]
    size = spec["size"]
    rotation = spec.get("rotation") or [0.0, 0.0, 0.0]
    sx, sy, sz = (float(size[0]), float(size[1]), float(size[2]))

    base = _link(object_id)
    _attach(base, group)
    base.location = Vector(_unity_to_blender_point(position))
    base.rotation_euler = blender_euler_from_unity(rotation)
    # 自定义属性：导出 glb/fbx 后仍可追溯语义类型
    base["dsh_type"] = type_
    base["dsh_category"] = entry["category"]
    # 几何模型映射（块 E）：优先真实模型，回退程序化图元
    mesh = _build_model_object(object_id, entry, base, sx, sy, sz)
    if mesh is not None:
        base["asset_source"] = "model"
        GEOMETRY_MAPPING_INFO["modelsUsed"] += 1
        return base
    base["asset_source"] = "primitive"
    GEOMETRY_MAPPING_INFO["primitivesFallback"] += 1
    for index, part in enumerate(entry["geometry"]):
        _build_geometry_part(part, object_id, index, sx, sy, sz, base)
    return base


def _normalize_plan(plan):
    bounds = plan.get("bounds") or DEFAULT_PLAN_BOUNDS
    width = float(bounds.get("width", DEFAULT_PLAN_BOUNDS["width"]))
    depth = float(bounds.get("depth", DEFAULT_PLAN_BOUNDS["depth"]))
    scene_name = str(plan.get("sceneName") or LLM_SCENE_NAME).strip() or LLM_SCENE_NAME
    objects = []
    for spec in plan.get("objects", []):
        group = spec.get("group") or PLAN_GROUP_BY_TYPE.get(spec["type"], "Props")
        objects.append(
            {
                "id": str(spec["id"]),
                "type": str(spec["type"]),
                "position": [float(value) for value in spec["position"]],
                "size": [float(value) for value in spec["size"]],
                "rotation": [float(value) for value in (spec.get("rotation") or [0.0, 0.0, 0.0])],
                "group": group,
            }
        )
    return {"sceneName": scene_name, "bounds": {"width": width, "depth": depth}, "objects": objects}


def _default_camera(bounds):
    """LLM 模式的默认相机：从场地右前方俯视，保证整个 bounds 都在视野内。"""
    width = float(bounds["width"])
    depth = float(bounds["depth"])
    span = max(width, depth)
    return (
        [round(width * 1.15, 3), round(max(12.0, span * 1.0), 3), round(depth * 1.15, 3)],
        [0.0, round(max(1.0, span * 0.08), 3), 0.0],
    )


def _plan_position_for_axis(position, axis):
    """plan 的 Unity Y-up 位置 → layout 坐标（z-up 时换成 Blender 原生坐标）。"""
    values = [float(position[0]), float(position[1]), float(position[2])]
    if axis == "z-up":
        return layout_point(_unity_to_blender_point(values), "z-up")
    return [num(value) for value in values]


def _plan_rotation_for_axis(rotation, axis):
    """plan 的 Unity ZXY 旋转（度）→ layout 旋转（z-up 时换成 Blender XYZ 度）。"""
    values = [float(value) for value in (rotation or [0.0, 0.0, 0.0])]
    if axis == "z-up":
        ex, ey, ez = blender_euler_from_unity(values)  # 返回弧度三元组
        return [num(math.degrees(ex)), num(math.degrees(ey)), num(math.degrees(ez))]
    return [num(value) for value in values]


def _llm_sun_zup_euler():
    """LLM 模式的固定太阳光（Unity pitch/yaw [38,42,0]）→ Blender XYZ 欧拉角（度）。"""
    direction = _unity_directional_to_blender([38.0, 42.0, 0.0])
    euler = direction.to_track_quat("-Z", "Y").to_euler("XYZ")
    return [num(math.degrees(euler.x)), num(math.degrees(euler.y)), num(math.degrees(euler.z))]


def layout_from_plan(plan, axis):
    """plan → layout.json 契约（axis 决定坐标语义；对象位置/旋转按 axis 换算，scale 恒 1）。"""
    scene_name = plan["sceneName"]
    groups = [
        {
            "name": "Terrain",
            "objects": [
                {
                    "asset": ASSET_NAME,
                    "instanceName": "Ground",
                    "position": [0.0, 0.0, 0.0],
                    "rotation": [0.0, 0.0, 0.0],
                    "scale": [1.0, 1.0, 1.0],
                }
            ],
        }
    ]
    for group_name in ("Buildings", "Props"):
        objects = []
        for spec in plan["objects"]:
            if spec["group"] != group_name:
                continue
            objects.append(
                {
                    "asset": ASSET_NAME,
                    "instanceName": spec["id"],
                    "position": _plan_position_for_axis(spec["position"], axis),
                    "rotation": _plan_rotation_for_axis(spec["rotation"], axis),
                    "scale": [1.0, 1.0, 1.0],
                }
            )
        if objects:
            groups.append({"name": group_name, "objects": objects})

    camera_position, camera_look_at = _default_camera(plan["bounds"])
    if axis == "z-up":
        # 默认相机参数是按 Unity Y-up 写的，z-up 下换成 Blender 坐标
        camera_position = layout_point(_unity_to_blender_point(camera_position), "z-up")
        camera_look_at = layout_point(_unity_to_blender_point(camera_look_at), "z-up")
    directional_rotation_value = _llm_sun_zup_euler() if axis == "z-up" else [38.0, 42.0, 0.0]
    return {
        "sceneName": f"{scene_name}",
        "root": f"{scene_name}_Root",
        "axis": axis,
        "groups": groups,
        "lighting": {
            "ambient": dict(AMBIENT_DEFAULT),
            "directional": {
                "intensity": 3.2,
                "rotation": directional_rotation_value,
                "color": [1.0, 0.95, 0.86],
                "name": SUN_NAME,
            },
            "skybox": "default",
        },
        "camera": {"position": camera_position, "lookAt": camera_look_at, "name": CAMERA_NAME},
        "prefab": {"enabled": False, "path": "Assets/Prefabs/"},
    }


def build_llm_scene(plan, axis):
    """清空场景，按 plan 建分组 Empty + 地面 + 每个对象的图元装配体。"""
    _clear_scene()
    layout = layout_from_plan(plan, axis)
    groups = {name: _link(name) for name in ("Terrain", "Buildings", "Props")}
    _add_plane("Ground", plan["bounds"]["width"], plan["bounds"]["depth"], _material("ground"), groups["Terrain"])
    for spec in plan["objects"]:
        _build_plan_object(spec, groups[spec["group"]])
    return layout



# =====================================================================
# 可选增强：SuperPBR 贴图生成（块 C，enableTextureGeneration 默认关闭）
#
# 流程（每个目标对象）：
#   1) 隔离渲染：只显示该对象子树，灰底 EEVEE 正面视角渲染 512x512 输入图；
#   2) Smart UV Project（保证贴图有可用 UV）；
#   3) 上传输入图 → 提交 pbr 工作流（SuperPBR + MoGe）→ 轮询 → 下载 5 张贴图；
#   4) 新建 LLM_<id>_pbr 材质并连到 Principled BSDF，替换子网格原 LLM_<key>。
# 任何单对象失败只记录，不中断主流水线；节点/模型缺失时直接 SKIP 并给出安装提示。
# =====================================================================

TEXTURE_MODEL = "superpbr"
TEXTURE_TIMEOUT_SECONDS = 120
TEXTURE_MAX_OBJECTS = 12
TEXTURE_NODE_KINDS = {
    "11": "albedo",
    "12": "normal",
    "13": "roughness",
    "14": "metallic",
    "15": "ao",
    "16": "height",
}
TEXTURE_REQUIRED_NODES = (
    "SuperPBRModelLoader",
    "SuperPBRDecompose",
    "SuperPBRORMSplit",
    "MoGeInference",
    "LoadMoGeModel",
    "MoGeRender",
)
TEXTURE_MAIN_TYPES = ("terrain", "column", "wall", "archway", "gatehouse")


def _http_json(url, payload=None, timeout=60):
    import urllib.request

    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf8")
        headers["content-type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf8"))


def _http_bytes(url, timeout=60):
    import urllib.request

    request = urllib.request.Request(url)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _http_upload_image(comfy_url, path, timeout=120):
    """multipart/form-data 上传一张 PNG 到 ComfyUI 的 input 目录。"""
    import urllib.request
    import uuid

    boundary = "----dsh" + uuid.uuid4().hex
    filename = Path(path).name
    payload = Path(path).read_bytes()
    body = b"".join(
        [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="image"; filename="{filename}"\r\n'.encode(),
            b"Content-Type: image/png\r\n\r\n",
            payload,
            f"\r\n--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="overwrite"\r\n\r\ntrue\r\n',
            f"--{boundary}--\r\n".encode(),
        ]
    )
    request = urllib.request.Request(
        comfy_url.rstrip("/") + "/upload/image",
        data=body,
        headers={"content-type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf8"))


def _strip_type_suffix(name):
    """column_01 → column；arch → arch；gatehouse_2 → gatehouse。"""
    parts = str(name).rsplit("_", 1)
    if len(parts) == 2 and parts[1].isdigit():
        return parts[0]
    return str(name)


def _object_type(obj):
    value = obj.get("dsh_type")
    if value:
        return str(value)
    return _strip_type_suffix(obj.name)


def _texture_targets(groups, mode):
    """返回 (base_object, group_name) 列表：main = 地形 + 主要建筑；all = 全部对象。"""
    targets = []
    for group_name in ("Terrain", "Buildings", "Props"):
        group = groups.get(group_name)
        if group is None:
            continue
        for child in group.children:
            if mode == "main":
                if group_name == "Props":
                    continue
                if group_name == "Buildings" and _object_type(child) not in TEXTURE_MAIN_TYPES:
                    continue
            targets.append((child, group_name))
    return targets


def _is_in_subtree(node, root):
    """node 是否等于 root 或位于 root 的子树里（含 root 自身）。"""
    current = node
    while current is not None:
        if current == root:
            return True
        current = current.parent
    return False


def _mesh_descendants(obj):
    meshes = []

    def walk(node):
        for child in node.children:
            if child.type == "MESH":
                meshes.append(child)
            walk(child)

    if obj.type == "MESH":
        meshes.append(obj)
    walk(obj)
    return meshes


def _world_bounds(meshes):
    from mathutils import Vector

    minimum = None
    maximum = None
    for mesh in meshes:
        for corner in mesh.bound_box:
            point = mesh.matrix_world @ Vector(corner)
            minimum = point.copy() if minimum is None else Vector(
                (min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
            )
            maximum = point.copy() if maximum is None else Vector(
                (max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
            )
    if minimum is None or maximum is None:
        return None
    return minimum, maximum


def _smart_uv(mesh):
    """Smart UV Project；对象已有可用 UV 也重投影一次，保证贴图映射一致。"""
    import math

    bpy.ops.object.select_all(action="DESELECT")
    mesh.select_set(True)
    bpy.context.view_layer.objects.active = mesh
    try:
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.smart_project(angle_limit=math.radians(66.0), island_margin=0.02)
    finally:
        bpy.ops.object.mode_set(mode="OBJECT")
        mesh.select_set(False)


def _isolated_render(base_obj, out_path, resolution):
    """只显示目标对象子树，灰底 + 正面相机 + 柔和阳光，渲染输入图；结束后恢复场景。"""
    import math
    from mathutils import Vector

    meshes = _mesh_descendants(base_obj)
    if not meshes:
        raise RuntimeError("对象没有网格子节点，无法渲染输入图")
    bounds = _world_bounds(meshes)
    if bounds is None:
        raise RuntimeError("无法计算对象包围盒")
    minimum, maximum = bounds
    center = (minimum + maximum) / 2.0
    size = maximum - minimum
    span = max(size.x, size.y, size.z, 0.1)

    scene = bpy.context.scene
    hidden = []
    for obj in bpy.data.objects:
        if _is_in_subtree(obj, base_obj):
            continue
        if _is_in_subtree(base_obj, obj):
            continue
        if obj.hide_render:
            continue
        obj.hide_render = True
        hidden.append(obj)

    # 相机
    camera_data = bpy.data.cameras.new("DSH_TextureCamera")
    camera = bpy.data.objects.new("DSH_TextureCamera", camera_data)
    scene.collection.objects.link(camera)
    camera_data.lens = 50.0
    # 按包围球和相机视角算距离，让主体占画面约 80%
    radius = max((maximum - minimum).length * 0.5, 0.2)
    fov = 2.0 * math.atan(camera_data.sensor_width / (2.0 * camera_data.lens))
    distance = radius / math.tan(fov / 2.0) * 1.05
    camera.location = Vector((center.x, center.y - distance, center.z + size.z * 0.15))
    direction = center - camera.location
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    previous_camera = scene.camera
    scene.camera = camera

    # 相机方向的柔和阳光（避免阴天/死黑）
    sun_data = bpy.data.lights.new("DSH_TextureSun", type="SUN")
    sun_data.energy = 3.0
    sun = bpy.data.objects.new("DSH_TextureSun", sun_data)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(50.0), 0.0, math.radians(-35.0))

    # 世界背景灰
    world = scene.world or bpy.data.worlds.new("DSH_TextureWorld")
    scene.world = world
    world.use_nodes = True
    background = world.node_tree.nodes.get("Background")
    previous_world_color = None
    if background is not None:
        previous_world_color = tuple(background.inputs["Color"].default_value)
        background.inputs["Color"].default_value = (0.5, 0.5, 0.5, 1.0)

    previous_engine = scene.render.engine
    previous_resolution = (scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage)
    previous_samples = getattr(scene.eevee, "taa_render_samples", None)
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
        if previous_samples is not None:
            scene.eevee.taa_render_samples = 16
        scene.render.resolution_x = int(resolution)
        scene.render.resolution_y = int(resolution)
        scene.render.resolution_percentage = 100
        scene.render.image_settings.file_format = "PNG"
        scene.render.filepath = str(out_path)
        bpy.ops.render.render(write_still=True)
    finally:
        scene.render.engine = previous_engine
        scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = previous_resolution
        if previous_samples is not None:
            scene.eevee.taa_render_samples = previous_samples
        scene.camera = previous_camera
        bpy.data.objects.remove(sun, do_unlink=True)
        bpy.data.objects.remove(camera, do_unlink=True)
        bpy.data.cameras.remove(camera_data)
        bpy.data.lights.remove(sun_data)
        if background is not None and previous_world_color is not None:
            background.inputs["Color"].default_value = previous_world_color
        for obj in hidden:
            obj.hide_render = False


def _texture_workflow(workflow_path, object_id, input_name, resolution):
    workflow = json.loads(Path(workflow_path).expanduser().read_text("utf8"))
    workflow = json.loads(json.dumps(workflow))
    for node in workflow.values():
        inputs = node.get("inputs", {})
        if node.get("class_type") == "LoadImage":
            inputs["image"] = input_name
        if node.get("class_type") == "SuperPBRDecompose":
            inputs["resolution"] = int(resolution)
        if node.get("class_type") == "SaveImage":
            prefix = str(inputs.get("filename_prefix", ""))
            inputs["filename_prefix"] = prefix.replace("__ID__", object_id)
    return workflow


def _wait_history(comfy_url, prompt_id, timeout, poll_interval=1.5):
    import time

    deadline = time.time() + timeout
    while time.time() < deadline:
        history = _http_json(f"{comfy_url.rstrip('/')}/history/{prompt_id}", timeout=30)
        if prompt_id in history:
            return history[prompt_id]
        time.sleep(poll_interval)
    raise RuntimeError(f"ComfyUI 出图超时（{timeout}s）")


def _pick_texture_image(outputs, kind):
    """按文件名后缀匹配贴图（SaveImage 前缀已注入 {id}_{kind}），节点 id 仅作兜底。"""
    for node_output in (outputs or {}).values():
        for image in (node_output or {}).get("images") or []:
            name = str(image.get("filename") or "")
            if f"_{kind}_" in name or name.endswith(f"_{kind}.png"):
                return image
    node_id = next((nid for nid, k in TEXTURE_NODE_KINDS.items() if k == kind), None)
    images = ((outputs or {}).get(node_id) or {}).get("images") or [] if node_id else []
    return images[0] if images else None


def _download_textures(comfy_url, entry, textures_dir, object_id):
    textures = {}
    outputs = entry.get("outputs", {}) or {}
    for kind in dict.fromkeys(TEXTURE_NODE_KINDS.values()):
        image = _pick_texture_image(outputs, kind)
        if image is None:
            continue
        filename = image.get("filename")
        subfolder = image.get("subfolder") or ""
        url = (
            f"{comfy_url.rstrip('/')}/view?filename={filename}"
            f"&subfolder={subfolder}&type={image.get('type') or 'output'}"
        )
        target = Path(textures_dir) / f"{object_id}_{kind}.png"
        target.write_bytes(_http_bytes(url))
        textures[kind] = str(target)
    return textures


def _apply_pbr_material(base_obj, object_id, textures):
    """把贴图连到 Principled BSDF，并用 LLM_<id>_pbr 替换子网格上的原材质。"""
    material = bpy.data.materials.get(f"LLM_{object_id}_pbr")
    if material is None:
        material = bpy.data.materials.new(f"LLM_{object_id}_pbr")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (420, 0)
    principled = nodes.new("ShaderNodeBsdfPrincipled")
    principled.location = (120, 0)
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])

    def add_image(path, label, x, y):
        image = bpy.data.images.load(str(path), check_existing=True)
        node = nodes.new("ShaderNodeTexImage")
        node.image = image
        node.label = label
        node.location = (x, y)
        return node

    albedo = textures.get("albedo")
    if albedo:
        node = add_image(albedo, "albedo", -420, 240)
        links.new(node.outputs["Color"], principled.inputs["Base Color"])
    normal = textures.get("normal")
    if normal:
        node = add_image(normal, "normal", -420, 0)
        node.image.colorspace_settings.name = "Non-Color"
        normal_map = nodes.new("ShaderNodeNormalMap")
        normal_map.location = (-120, 0)
        links.new(node.outputs["Color"], normal_map.inputs["Color"])
        links.new(normal_map.outputs["Normal"], principled.inputs["Normal"])
    roughness = textures.get("roughness")
    if roughness:
        node = add_image(roughness, "roughness", -420, -240)
        node.image.colorspace_settings.name = "Non-Color"
        links.new(node.outputs["Color"], principled.inputs["Roughness"])
    metallic = textures.get("metallic")
    if metallic:
        node = add_image(metallic, "metallic", -420, -480)
        node.image.colorspace_settings.name = "Non-Color"
        links.new(node.outputs["Color"], principled.inputs["Metallic"])

    for mesh in _mesh_descendants(base_obj):
        mesh.data.materials.clear()
        mesh.data.materials.append(material)
    return material


def _check_texture_support(comfy_url):
    """返回 (reason, moge_available)：reason 为 None 表示可跑 SuperPBR；MoGe 可选。"""
    required = ("SuperPBRModelLoader", "SuperPBRDecompose", "SuperPBRORMSplit")
    for node in required:
        try:
            _http_json(f"{comfy_url.rstrip('/')}/object_info/{node}", timeout=15)
        except Exception:  # noqa: BLE001 —— 节点缺失或服务不可达
            return f"SKIP: SuperPBR 节点不可用（缺少 {node}），请先安装 ComfyUI-SuperPBR 并重启 ComfyUI", False
    try:
        base = comfy_url.rstrip("/")
        supermat = _http_json(f"{base}/object_info/SuperPBRModelLoader", timeout=15)
        options = (supermat.get("SuperPBRModelLoader", {}).get("input", {}).get("required", {}).get("model") or [[]])[0]
        if not options:
            return "SKIP: 未找到 SuperMat 模型（把 supermat.pth 放到 ComfyUI/models/diffusion_models/ 并重启）", False
        vae = _http_json(f"{base}/object_info/VAELoader", timeout=15)
        vae_options = (vae.get("VAELoader", {}).get("input", {}).get("required", {}).get("vae_name") or [[]])[0]
        if not any("vae-ft-mse" in str(name) for name in vae_options):
            return "SKIP: 未找到 VAE（把 vae-ft-mse-840000-ema-pruned.safetensors 放到 ComfyUI/models/vae/ 并重启）", False
        moge_available = False
        try:
            for node in ("LoadMoGeModel", "MoGeInference", "MoGeRender"):
                _http_json(f"{base}/object_info/{node}", timeout=10)
            moge = _http_json(f"{base}/object_info/LoadMoGeModel", timeout=10)
            moge_options = (moge.get("LoadMoGeModel", {}).get("input", {}).get("required", {}).get("model_name") or [[]])[0]
            moge_available = bool(moge_options)
        except Exception:  # noqa: BLE001 —— MoGe 不可用只影响法线
            moge_available = False
    except Exception as error:  # noqa: BLE001
        return f"SKIP: 无法访问 ComfyUI 节点信息（{error}）", False
    return None, moge_available


def apply_pbr_materials(texture_config, groups):
    """块 C：为可选对象生成 SuperPBR 贴图并替换材质（不阻断主流水线）。"""
    import time

    if not texture_config or not texture_config.get("enabled"):
        return None

    comfy_url = str(texture_config.get("comfyUrl") or "http://127.0.0.1:8188").rstrip("/")
    workflow_path = texture_config.get("workflowPath")
    textures_dir = Path(str(texture_config.get("texturesDir") or "")).expanduser()
    resolution = int(texture_config.get("resolution") or 512)
    mode = "all" if texture_config.get("objects") == "all" else "main"
    timeout_seconds = int(texture_config.get("timeoutSeconds") or TEXTURE_TIMEOUT_SECONDS)

    info = {
        "enabled": True,
        "model": TEXTURE_MODEL,
        "resolution": resolution,
        "objects": mode,
        "objectCount": 0,
        "failedCount": 0,
    }
    if not workflow_path or not Path(str(workflow_path)).exists():
        info["error"] = "SKIP: 找不到 pbr 工作流 JSON（lib/workflows/pbr-superpbr.json）"
        return info
    if not str(textures_dir):
        info["error"] = "SKIP: 未指定贴图输出目录"
        return info

    reason, moge_available = _check_texture_support(comfy_url)
    if reason:
        info["error"] = reason
        return info
    lite_path = texture_config.get("workflowLitePath")
    if moge_available and lite_path and Path(str(lite_path)).exists():
        pass  # full 工作流带法线，优先用
    elif lite_path and Path(str(lite_path)).exists():
        workflow_path = lite_path
        moge_available = False
    info["workflow"] = "full" if moge_available else "lite"
    if not moge_available:
        info["note"] = "MoGe 不可用，已跳过法线/高度贴图（只生成 albedo/roughness/metallic/ao）"

    textures_dir.mkdir(parents=True, exist_ok=True)
    info["texturesDir"] = str(textures_dir)
    targets = _texture_targets(groups, mode)
    if len(targets) > TEXTURE_MAX_OBJECTS:
        info["note"] = f"对象过多，只给前 {TEXTURE_MAX_OBJECTS} 个出贴图（共 {len(targets)} 个）"
        targets = targets[:TEXTURE_MAX_OBJECTS]
    failures = []
    for index, (base_obj, group_name) in enumerate(targets):
        object_id = base_obj.name
        started = time.time()
        try:
            for mesh in _mesh_descendants(base_obj):
                _smart_uv(mesh)
            input_path = textures_dir / f"{object_id}_input.png"
            _isolated_render(base_obj, input_path, resolution)
            uploaded = _http_upload_image(comfy_url, input_path, timeout=120)
            input_name = uploaded.get("name") or input_path.name
            current_workflow = workflow_path
            workflow = _texture_workflow(current_workflow, object_id, input_name, resolution)
            submitted = _http_json(f"{comfy_url}/prompt", {"prompt": workflow, "client_id": "dsh-scene-skeleton"}, timeout=60)
            prompt_id = submitted.get("prompt_id")
            if not prompt_id:
                raise RuntimeError(f"ComfyUI 未返回 prompt_id（{str(submitted)[:200]}）")
            entry = _wait_history(comfy_url, prompt_id, timeout_seconds)
            status = entry.get("status") or {}
            if status.get("status_str") not in (None, "success") and lite_path and Path(str(lite_path)).exists() and current_workflow != lite_path:
                # MoGe/法线链路在这台机器上跑不动（如 MPS 不支持某些半精度算子）→ 回退 lite 再试一次
                print("[texture] full 工作流失败，回退 lite（无 MoGe 法线）", flush=True)
                current_workflow = lite_path
                workflow = _texture_workflow(current_workflow, object_id, input_name, resolution)
                submitted = _http_json(f"{comfy_url}/prompt", {"prompt": workflow, "client_id": "dsh-scene-skeleton"}, timeout=60)
                prompt_id = submitted.get("prompt_id") or ""
                entry = _wait_history(comfy_url, prompt_id, timeout_seconds)
                status = entry.get("status") or {}
                info["workflow"] = "lite"
            if status.get("status_str") not in (None, "success"):
                raise RuntimeError(f"ComfyUI 执行状态 {status.get('status_str')}")
            textures = _download_textures(comfy_url, entry, textures_dir, object_id)
            if not textures.get("albedo"):
                raise RuntimeError("没有拿到 albedo 贴图")
            _apply_pbr_material(base_obj, object_id, textures)
            info["objectCount"] += 1
        except Exception as error:  # noqa: BLE001 —— 单对象失败只记录
            info["failedCount"] += 1
            failures.append({"object": object_id, "error": str(error)})
        finally:
            elapsed = round(time.time() - started, 1)
            print(f"[texture] {object_id} {group_name} {elapsed}s", flush=True)

    if failures:
        info["failed"] = failures
        info["error"] = f"{len(failures)} 个对象贴图生成失败（首个：{failures[0]['object']}：{failures[0]['error']}）"
    return info


def main():
    # 位置参数（Blender 的 `--` 之后只传位置参数最稳，避免 Blender 自身 argparse 抢 --flag）。
    # Blender 会把完整命令行塞进 sys.argv（含 --background/--python 等），只取 `--` 之后的部分。
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]
    else:
        argv = []
    parser = argparse.ArgumentParser(prog="run_scenic")
    parser.add_argument("spec")
    parser.add_argument("out_blend")
    parser.add_argument("out_gltf")
    parser.add_argument("out_fbx")
    parser.add_argument("out_layout")
    parser.add_argument("params_json", nargs="?", default="{}")
    args = parser.parse_args(argv)

    try:
        params = json.loads(args.params_json)
        scene_source = str(params.pop("sceneSource", "template")).strip().lower()
        if scene_source not in ("template", "llm"):
            raise RuntimeError(f"未知的 sceneSource：{scene_source}（只支持 template / llm）")
        layout_axis = str(params.pop("layoutAxis", "z-up")).strip().lower()
        if layout_axis not in LAYOUT_AXES:
            raise RuntimeError(f"未知的 layoutAxis：{layout_axis}（只支持 z-up / y-up）")
        # layoutValidation 只服务于 llm 分支的物理校验，不能传给 scenic 的 scene 组件
        layout_validation = params.pop("layoutValidation", None)
        # 块 C：可选贴图生成配置（同样不能传给 scenic 的 scene 组件）
        texture_config = params.pop("texture", None)
        # 块 D：材质映射（asset-library 材质贴图根目录）
        material_mapping_config = params.pop("materialMapping", None)
        configure_material_mapping(material_mapping_config)
        # 块 E：几何模型映射（asset-library 真实模型根目录）
        model_mapping_config = params.pop("modelMapping", None)
        configure_model_mapping(model_mapping_config)

        layout_path = Path(args.out_layout).expanduser().resolve()
        layout_path.parent.mkdir(parents=True, exist_ok=True)

        if scene_source == "llm":
            layout_objects = params.pop("layoutObjects", "") or params.pop("planPath", "")
            if not str(layout_objects).strip():
                raise RuntimeError("sceneSource='llm' 需要 layoutObjects（plan JSON 文件路径或内联 JSON）")
            raw_plan = load_plan(str(layout_objects))
            validation = validate_plan(raw_plan, layout_validation)
            if not validation["ok"]:
                messages = [error["message"] for error in validation["errors"]]
                raise RuntimeError("布局校验失败：\n- " + "\n- ".join(messages))
            plan = _normalize_plan(raw_plan)
            layout = build_llm_scene(plan, layout_axis)
            stats = {"objects": len(bpy.data.objects), "materials": len(bpy.data.materials)}
        else:
            app = load_app(args.spec)
            scenes = app.by_kind("scene")
            if len(scenes) != 1:
                raise RuntimeError(f"需要恰好一个 @app.scene()，实际 {len(scenes)} 个：{', '.join(scenes) or '(无)'}")
            component = next(iter(scenes.values()))
            scene_spec = component(**params)

            layout = build_layout(scene_spec, layout_axis)

            from scenic.compile import compiler

            compiler.fresh_file()
            stats = compiler.build(scene_spec)

        # ---- Blender 装配：Empty 层级 + 光照 + 世界背景 + 相机 ----
        assemble_hierarchy(layout)
        configure_lights(layout, layout_axis)
        configure_world()
        configure_camera(layout, layout_axis)

        # ---- 可选：SuperPBR 贴图生成（默认关闭；失败只记录，不阻断主线）----
        texture_info = None
        if texture_config:
            groups = {name: bpy.data.objects.get(name) for name in ("Terrain", "Buildings", "Props")}
            try:
                texture_info = apply_pbr_materials(texture_config, groups)
            except Exception as error:  # noqa: BLE001 —— 贴图是可选增强
                texture_info = {"enabled": True, "error": f"贴图生成异常：{error}"}

        # ---- 保存 .blend（层级/光照/相机/世界背景都在里面）----
        blend_path = Path(args.out_blend).expanduser().resolve()
        blend_path.parent.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(blend_path))

        # ---- 导出 .fbx（全场景，保留 Empty 层级，不二次烘焙坐标系）----
        fbx_path = Path(args.out_fbx).expanduser().resolve()
        fbx_path.parent.mkdir(parents=True, exist_ok=True)
        bpy.ops.export_scene.fbx(
            filepath=str(fbx_path),
            use_selection=False,
            object_types={"EMPTY", "MESH", "LIGHT", "CAMERA"},
            bake_space_transform=False,
            apply_unit_scale=True,
        )

        # ---- 导出 .glb（引擎无关备份，glTF 规范 Y-up）----
        gltf_path = Path(args.out_gltf).expanduser().resolve()
        gltf_path.parent.mkdir(parents=True, exist_ok=True)
        bpy.ops.export_scene.gltf(
            filepath=str(gltf_path),
            export_format="GLB",
            use_selection=False,
            export_yup=True,
            export_cameras=True,
            export_lights=True,
        )

        # 写 layout.json（最后写，作为「装配完成」的契约快照）
        layout_path.write_text(json.dumps(layout, ensure_ascii=False, indent=2) + "\n", "utf8")

        object_count = sum(len(group["objects"]) for group in layout["groups"])
        result = {
            "mode": scene_source,
            "sceneSource": scene_source,
            "axis": layout_axis,
            "blend": str(blend_path),
            "blendBytes": blend_path.stat().st_size,
            "glb": str(gltf_path),
            "glbBytes": gltf_path.stat().st_size,
            "fbx": str(fbx_path),
            "bytes": fbx_path.stat().st_size,
            "objects": stats.get("objects", object_count),
            "materials": stats.get("materials", 0),
            "layout": str(layout_path),
            "root": layout["root"],
            "groups": [group["name"] for group in layout["groups"]],
            "groupObjects": {group["name"]: len(group["objects"]) for group in layout["groups"]},
            "objectCount": object_count,
        }
        if texture_info is not None:
            result["texture"] = texture_info
        result["materialMapping"] = {
            "enabled": MATERIAL_MAPPING_INFO["enabled"],
            "assetLibraryPath": MATERIAL_MAPPING_INFO["assetLibraryPath"],
            "keysWithTextures": sorted(set(MATERIAL_MAPPING_INFO["keysWithTextures"])),
            "keysFallback": sorted(set(MATERIAL_MAPPING_INFO["keysFallback"])),
        }
        result["geometryMapping"] = {
            "modelsUsed": GEOMETRY_MAPPING_INFO["modelsUsed"],
            "primitivesFallback": GEOMETRY_MAPPING_INFO["primitivesFallback"],
        }
        print(f"DSH_BLENDER_RESULT:{json.dumps(result, ensure_ascii=False)}")
        return 0
    except Exception as error:  # noqa: BLE001 —— 运行器要把一切错误转成标记
        print(f"DSH_BLENDER_ERROR:{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
