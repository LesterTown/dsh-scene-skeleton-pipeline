"""布局计划（plan）校验，纯 Python 实现（不需要 bpy，可用 Blender 自带 python 直接跑）。

用法：
  python3 layout_validate.py <plan.json> [options.json]

打印错误列表；有错误时 exit 1，无错误时 exit 0 并输出 {ok: true, objectCount}。

plan 与 lib/layout.js 里的 schema 一致（Unity Y-up、单位米）：
{
  "sceneName": "LLMScene",
  "bounds": {"width": 24, "depth": 20},
  "objects": [
    {"id": "column_01", "type": "column", "position": [0, 0, 0],
     "size": [0.6, 3, 0.6], "rotation": [0, 0, 0], "group": "Buildings"}
  ]
}

position 是物体的底面中心（y=0 贴地），size 是完整尺寸。

校验分两层：
1) 结构：id / type / group / 尺寸范围 / plan bounds；
2) 物理合理性（AABB 级，不做物理模拟）：
   - bounds：世界包围盒不得超出场景边界（options.sceneBounds，默认 ±50m）；
   - ground：底部不得沉入地面（容差 options.groundTolerance）；
   - float：底部不得悬空高于 options.maxFloatHeight，placement 含 wall/ceiling 的对象豁免；
   - collision：两对象三轴重叠都超过 options.maxCollisionOverlap 判为碰撞；
   - support：placement 含 on_surface 的悬空对象，下方必须有一个顶面接近其底部、
     水平覆盖其 ≥50% 的支撑对象。
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Any

# 语义资产库：type 白名单 / 分组 / 尺寸范围唯一事实源
ASSET_LIBRARY_PATH = Path(__file__).resolve().parent.parent / "asset-library.json"
with open(ASSET_LIBRARY_PATH, "r", encoding="utf-8") as _library_handle:
    ASSET_LIBRARY = json.load(_library_handle)
ASSETS_BY_TYPE = {entry["type"]: entry for entry in ASSET_LIBRARY["assets"]}

PLAN_TYPES = [entry["type"] for entry in ASSET_LIBRARY["assets"]]
GROUP_BY_TYPE = {entry["type"]: entry["category"] for entry in ASSET_LIBRARY["assets"]}
PLACEMENT_BY_TYPE = {
    entry["type"]: list(entry.get("placement") or ["ground"]) for entry in ASSET_LIBRARY["assets"]
}
ALLOWED_GROUPS = sorted({entry["category"] for entry in ASSET_LIBRARY["assets"]})

# height = size[1]；footprint = max(size[0], size[2])；min = 每个分量的下限。
SIZE_RANGES = {
    entry["type"]: {
        "height": tuple(float(value) for value in entry["sizeRange"]["height"]),
        "footprint": tuple(float(value) for value in entry["sizeRange"]["footprint"]),
        "min": float(entry["sizeRange"]["min"]),
    }
    for entry in ASSET_LIBRARY["assets"]
}

MAX_OBJECTS = 120
DEFAULT_BOUNDS = {"width": 24.0, "depth": 20.0}

# 物理校验默认参数（可由 layoutValidation 配置覆盖）
DEFAULT_VALIDATION = {
    "maxCollisionOverlap": 0.1,
    "maxFloatHeight": 0.3,
    "groundTolerance": 0.05,
    "sceneBounds": [-50.0, 50.0],
}

# 允许脱离地面摆放的 placement 取值
EXEMPT_PLACEMENTS = ("wall", "ceiling")


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _is_vec3(value: Any) -> bool:
    return isinstance(value, (list, tuple)) and len(value) == 3 and all(_is_number(item) for item in value)


def _fmt(value: float) -> str:
    return f"{value:.3f}".rstrip("0").rstrip(".")


def merge_options(options: Any = None) -> dict[str, Any]:
    """把用户传入的 layoutValidation 覆盖到默认参数上。"""
    merged = dict(DEFAULT_VALIDATION)
    if isinstance(options, dict):
        for key in ("maxCollisionOverlap", "maxFloatHeight", "groundTolerance"):
            value = options.get(key)
            if _is_number(value) and float(value) >= 0:
                merged[key] = float(value)
        scene_bounds = options.get("sceneBounds")
        if (
            isinstance(scene_bounds, (list, tuple))
            and len(scene_bounds) == 2
            and all(_is_number(value) for value in scene_bounds)
            and float(scene_bounds[0]) < float(scene_bounds[1])
        ):
            merged["sceneBounds"] = [float(scene_bounds[0]), float(scene_bounds[1])]
    return merged


def _aabb(position: list[float], size: list[float]) -> dict[str, float]:
    px, py, pz = (float(position[0]), float(position[1]), float(position[2]))
    sx, sy, sz = (float(size[0]), float(size[1]), float(size[2]))
    return {
        "x1": px - sx / 2.0,
        "x2": px + sx / 2.0,
        "y1": py,
        "y2": py + sy,
        "z1": pz - sz / 2.0,
        "z2": pz + sz / 2.0,
    }


def _horizontal_overlap(a: dict[str, float], b: dict[str, float]) -> tuple[float, float]:
    return (
        min(a["x2"], b["x2"]) - max(a["x1"], b["x1"]),
        min(a["z2"], b["z2"]) - max(a["z1"], b["z1"]),
    )


def _find_support(
    box: dict[str, float], candidates: list[dict[str, float]], tolerance: float
) -> dict[str, float] | None:
    """在 candidates 里找一个「顶面接近 box 底部、水平覆盖 ≥50%」的支撑对象。"""
    area = max(0.0, (box["x2"] - box["x1"]) * (box["z2"] - box["z1"]))
    if area <= 0:
        return None
    for other in candidates:
        if other is box:
            continue
        if other["y2"] > box["y1"] + tolerance or other["y1"] >= box["y1"]:
            continue
        if abs(other["y2"] - box["y1"]) > tolerance:
            continue
        overlap_x, overlap_z = _horizontal_overlap(box, other)
        if overlap_x <= 0 or overlap_z <= 0:
            continue
        if overlap_x * overlap_z >= 0.5 * area:
            return other
    return None


def validate_plan(plan: Any, options: Any = None) -> dict[str, Any]:
    """校验布局计划，返回 {ok, errors:[{rule, message, objects}]}。"""
    settings = merge_options(options)
    ground_tolerance = float(settings["groundTolerance"])
    max_float = float(settings["maxFloatHeight"])
    max_collision = float(settings["maxCollisionOverlap"])
    scene_min, scene_max = (float(settings["sceneBounds"][0]), float(settings["sceneBounds"][1]))

    errors: list[dict[str, Any]] = []

    def add(rule: str, message: str, objects: list[str] | None = None) -> None:
        errors.append({"rule": rule, "message": message, "objects": objects or []})

    if not isinstance(plan, dict):
        add("schema", "plan 必须是一个 JSON 对象")
        return {"ok": False, "errors": errors}

    bounds = plan.get("bounds", DEFAULT_BOUNDS)
    if "bounds" in plan:
        if not isinstance(plan["bounds"], dict):
            add("schema", "bounds 必须是 {width, depth} 对象")
        else:
            for key in ("width", "depth"):
                value = plan["bounds"].get(key)
                if not _is_number(value) or value < 1 or value > 200:
                    add("schema", f"bounds.{key} 必须是 1–200 之间的数字")

    scene_name = plan.get("sceneName")
    if scene_name is not None and (not isinstance(scene_name, str) or scene_name.strip() == ""):
        add("schema", "sceneName 必须是非空字符串")

    objects = plan.get("objects")
    if not isinstance(objects, list) or len(objects) == 0:
        add("schema", "objects 必须是非空数组")
        return {"ok": False, "errors": errors}
    if len(objects) > MAX_OBJECTS:
        add("schema", f"objects 数量不能超过 {MAX_OBJECTS}（当前 {len(objects)}）")

    seen_ids: set[str] = set()
    boxes: list[dict[str, Any]] = []

    for index, obj in enumerate(objects):
        if not isinstance(obj, dict):
            add("schema", f"objects[{index}] 必须是对象")
            continue

        name = obj.get("id")
        label = name if isinstance(name, str) and name != "" else f"objects[{index}]"
        if not isinstance(name, str) or name.strip() == "":
            add("schema", f"objects[{index}].id 必须是非空字符串")
        elif any(ch.isspace() for ch in name) or len(name) > 64:
            add("schema", f"{label}.id 不能包含空白字符且长度不超过 64", [label])
        elif name in seen_ids:
            add("schema", f"{label}.id 重复", [label])
        else:
            seen_ids.add(name)

        obj_type = obj.get("type")
        if obj_type not in PLAN_TYPES:
            add(
                "schema",
                f"{label}.type 必须是 {'/'.join(PLAN_TYPES)} 之一（当前 {obj_type!r}）",
                [label],
            )
            continue
        ranges = SIZE_RANGES[obj_type]

        position = obj.get("position")
        size = obj.get("size")
        if not _is_vec3(position):
            add("schema", f"{label}.position 必须是 3 个数字", [label])
            continue
        if not _is_vec3(size):
            add("schema", f"{label}.size 必须是 3 个数字", [label])
            continue
        rotation = obj.get("rotation")
        if rotation is not None and not _is_vec3(rotation):
            add("schema", f"{label}.rotation 必须是 3 个数字", [label])
        group = obj.get("group")
        if group is not None and group not in ALLOWED_GROUPS:
            add("schema", f"{label}.group 只能是 {' / '.join(ALLOWED_GROUPS)}", [label])
        elif group is not None and group != GROUP_BY_TYPE[obj_type]:
            add(
                "schema",
                f"{label}.group 与 type 不匹配：{obj_type} 应属于 {GROUP_BY_TYPE[obj_type]}"
                f"（当前 {group}）",
                [label],
            )

        sx, sy, sz = (float(size[0]), float(size[1]), float(size[2]))
        px, py, pz = (float(position[0]), float(position[1]), float(position[2]))

        for axis, value in (("size.x", sx), ("size.y", sy), ("size.z", sz)):
            if value < ranges["min"]:
                add("size", f"{label}.{axis} 不能小于 {ranges['min']}（当前 {_fmt(value)}）", [label])
        if sy < ranges["height"][0] or sy > ranges["height"][1]:
            add(
                "size",
                f"{label} 高度 {_fmt(sy)} 超出 {obj_type} 的范围 {ranges['height'][0]}–{ranges['height'][1]}m",
                [label],
            )
        footprint = max(sx, sz)
        if footprint < ranges["footprint"][0] or footprint > ranges["footprint"][1]:
            add(
                "size",
                f"{label} 平面尺寸 {_fmt(footprint)} 超出 {obj_type} 的范围 "
                f"{ranges['footprint'][0]}–{ranges['footprint'][1]}m",
                [label],
            )

        box = _aabb(position, size)
        boxes.append(
            {
                "label": label,
                "type": obj_type,
                "placement": PLACEMENT_BY_TYPE.get(obj_type, ["ground"]),
                "box": box,
                "has_schema_error": any(label in err["objects"] for err in errors),
            }
        )

    # ---- 物理合理性校验（只对结构合法的对象做）----
    for entry in boxes:
        label = entry["label"]
        box = entry["box"]
        if entry["has_schema_error"]:
            continue
        bottom = box["y1"]

        # 1) 地面穿透
        if bottom < -ground_tolerance:
            add(
                "ground",
                f"{label} 沉入地面 {_fmt(-bottom)}m（底部 y={_fmt(bottom)}）",
                [label],
            )
            continue

        # 2) 场景边界（世界 AABB 越界）
        if box["x1"] < scene_min - 1e-6 or box["x2"] > scene_max + 1e-6:
            add(
                "bounds",
                f"{label} 的包围盒超出场景边界 [{_fmt(scene_min)}, {_fmt(scene_max)}]"
                f"（x 范围 {_fmt(box['x1'])}–{_fmt(box['x2'])}）",
                [label],
            )
        if box["z1"] < scene_min - 1e-6 or box["z2"] > scene_max + 1e-6:
            add(
                "bounds",
                f"{label} 的包围盒超出场景边界 [{_fmt(scene_min)}, {_fmt(scene_max)}]"
                f"（z 范围 {_fmt(box['z1'])}–{_fmt(box['z2'])}）",
                [label],
            )

        # 3) 悬浮 / on_surface 支撑
        placement = entry["placement"]
        if bottom > max_float:
            if "on_surface" in placement:
                support = _find_support(box, [other["box"] for other in boxes], max(ground_tolerance, 0.1))
                if support is None:
                    add(
                        "support",
                        f"{label} 声明为 on_surface，但下方无有效支撑面（底部 y={_fmt(bottom)}，"
                        f"需要顶面接近且水平覆盖 ≥50%）",
                        [label],
                    )
            elif any(item in EXEMPT_PLACEMENTS for item in placement):
                pass
            else:
                add(
                    "float",
                    f"{label} 悬浮 {_fmt(bottom)}m，placement={'/'.join(placement)} 不允许地面放置",
                    [label],
                )

    # 4) 碰撞（三轴都重叠超过容差）
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            a, b = boxes[i], boxes[j]
            if a["has_schema_error"] or b["has_schema_error"]:
                continue
            box_a, box_b = a["box"], b["box"]
            overlap_x = min(box_a["x2"], box_b["x2"]) - max(box_a["x1"], box_b["x1"])
            overlap_y = min(box_a["y2"], box_b["y2"]) - max(box_a["y1"], box_b["y1"])
            overlap_z = min(box_a["z2"], box_b["z2"]) - max(box_a["z1"], box_b["z1"])
            if overlap_x > max_collision and overlap_y > max_collision and overlap_z > max_collision:
                volume = overlap_x * overlap_y * overlap_z
                add(
                    "collision",
                    f"{a['label']} 与 {b['label']} 碰撞，三轴重叠 "
                    f"{_fmt(overlap_x)}×{_fmt(overlap_y)}×{_fmt(overlap_z)}m，"
                    f"重叠体积约 {_fmt(volume)}m³",
                    [a["label"], b["label"]],
                )

    return {"ok": not errors, "errors": errors}


def validate_layout(plan: Any, options: Any = None) -> list[str]:
    """兼容接口：返回中文错误消息列表（空表示通过）。"""
    return [error["message"] for error in validate_plan(plan, options)["errors"]]


def load_plan(text_or_path: str) -> Any:
    """从内联 JSON 文本或文件路径读取 plan。"""
    stripped = text_or_path.strip()
    if stripped.startswith("{"):
        return json.loads(stripped)
    with open(stripped, "r", encoding="utf-8") as handle:
        return json.load(handle)


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print("用法: layout_validate.py <plan.json> [options.json]", file=sys.stderr)
        return 2
    try:
        plan = load_plan(argv[1])
        options = json.loads(argv[2]) if len(argv) == 3 else None
    except Exception as exc:  # noqa: BLE001 - 命令行工具，报清楚即可
        print(f"读取输入失败：{exc}", file=sys.stderr)
        return 2
    result = validate_plan(plan, options)
    if result["errors"]:
        print("布局校验失败：", file=sys.stderr)
        for error in result["errors"]:
            print(f"- {error['message']}", file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, "objectCount": len(plan.get("objects", []))}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
