#!/usr/bin/env bash
# ============================================================================
# 阶段 7 块 2 验证：Blender 装配终点（Empty 层级 / 光照相机 / .blend / FBX / GLB / layout）
# ----------------------------------------------------------------------------
# 用法：
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-blender-export.sh
#
# 本脚本只验证 Blender 侧装配终点，不需要 ComfyUI / Unity（scenic courtyard
# 场景不依赖概念图）。它会：
#   [1] 用 run_scenic.py 生成 4 个产物（scene.blend / scene.glb / scene.fbx / layout.json）；
#   [2] 断言 .blend 存在且非空；
#   [3] 断言 .fbx 用 Blender 重导入后，SceneSkeleton_Root / Terrain / Buildings / Props
#       四个 Empty 都在、父子关系正确，且名字与 layout.json 一致；
#   [4] 断言 .glb 存在且结构有效（GLB 头 + JSON chunk 的 scenes/nodes/meshes/materials）；
#   [5] 断言 layout.json 的 lighting 与 camera 是实际值（非 schema 占位）。
# ============================================================================
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"

# Blender 可执行：优先环境变量，其次 macOS 常见路径，最后 PATH 里的 blender
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
[ -x "$BLENDER" ] || BLENDER="$(command -v blender 2>/dev/null || true)"
if [ -z "$BLENDER" ] || [ ! -x "$BLENDER" ]; then
  echo "FATAL: 找不到 Blender 可执行文件（可 export BLENDER=/path/to/blender）" >&2
  exit 1
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

WORK="$(mktemp -d /tmp/dsh-blender-export.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "[1] 生成 scenic 场景 4 产物（run_scenic.py）"
"$BLENDER" --background --factory-startup \
  --python "$PLUGIN_DIR/lib/scripts/run_scenic.py" -- \
  "$PLUGIN_DIR/lib/scripts/scenes/courtyard.py" \
  "$WORK/scene.blend" "$WORK/scene.glb" "$WORK/scene.fbx" "$WORK/layout.json" \
  '{"seed":42}' >"$WORK/blender.log" 2>&1
rc=$?
check_eq "run_scenic.py 退出码 0" "$rc" "0"
check "日志含 DSH_BLENDER_RESULT" "grep -q 'DSH_BLENDER_RESULT' '$WORK/blender.log'"

echo "[2] .blend 存在且非空"
check "scene.blend 非空" "[ -s '$WORK/scene.blend' ]"
BLEND_BYTES=$(wc -c <"$WORK/scene.blend" 2>/dev/null || echo 0)
check "scene.blend > 100 KB（实际 ${BLEND_BYTES}）" "[ \"${BLEND_BYTES}\" -gt 100000 ]"

echo "[3] .fbx 重导入：Empty 层级与父子关系"
cat >"$WORK/verify-fbx.py" <<'PY'
import bpy, json, sys
fbx = sys.argv[sys.argv.index("--") + 1]
layout_path = sys.argv[sys.argv.index("--") + 2]
layout = json.load(open(layout_path))
root = layout.get("root")
groups = [g["name"] for g in layout.get("groups", [])]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=fbx)
objs = {o.name: o for o in bpy.data.objects}

errors = []
if root not in objs:
    errors.append(f"root '{root}' 不在 fbx 中")
else:
    r = objs[root]
    kids = sorted(c.name for c in r.children)
    if kids != sorted(groups):
        errors.append(f"root 子节点 {kids} != groups {sorted(groups)}")

for g in groups:
    if g not in objs:
        errors.append(f"group '{g}' 不在 fbx 中")
        continue
    o = objs[g]
    if o.parent is None or o.parent.name != root:
        errors.append(f"group '{g}' 的父节点不是 '{root}'（实际 {o.parent.name if o.parent else None}）")
    if o.type != "EMPTY":
        errors.append(f"group '{g}' 不是 EMPTY（实际 {o.type}）")

# 光照与相机（layout 里的实际名字）
sun_name = layout.get("lighting", {}).get("directional", {}).get("name")
cam_name = layout.get("camera", {}).get("name")
if sun_name and sun_name not in objs:
    errors.append(f"太阳光 '{sun_name}' 不在 fbx 中")
if cam_name and cam_name not in objs:
    errors.append(f"相机 '{cam_name}' 不在 fbx 中")

if errors:
    print("FBX_VERIFY_FAIL: " + "; ".join(errors))
    sys.exit(1)
print(f"FBX_VERIFY_OK: root={root} groups={groups} sun={sun_name} camera={cam_name}")
PY
FBX_OUT="$("$BLENDER" --background --factory-startup --python "$WORK/verify-fbx.py" -- "$WORK/scene.fbx" "$WORK/layout.json" 2>&1 | grep -E 'FBX_VERIFY')"
check "fbx 层级验证通过（${FBX_OUT}）" "echo '${FBX_OUT}' | grep -q 'FBX_VERIFY_OK'"

echo "[4] .glb 结构有效 + layout 与 FBX 名一致 + lighting/camera 实际值"
python3 - "$WORK/scene.glb" "$WORK/layout.json" <<'PY'
import struct, json, sys

glb_path, layout_path = sys.argv[1], sys.argv[2]
errors = []

with open(glb_path, "rb") as f:
    data = f.read()
if len(data) < 12:
    print("GLB_LAYOUT_FAIL: glb 太短")
    sys.exit(1)
magic, version, total = struct.unpack("<III", data[:12])
if magic != 0x46546C67:
    errors.append(f"glb magic 0x{magic:08x} != 0x46546C67")
if version != 2:
    errors.append(f"glb version {version} != 2")
if total != len(data):
    errors.append(f"glb total {total} != 实际 {len(data)}")
# JSON chunk
clen, ctype = struct.unpack("<II", data[12:20])
j = json.loads(data[20:20 + clen])
if "scenes" not in j or len(j.get("scenes", [])) < 1:
    errors.append("glb 缺 scenes")
if len(j.get("nodes", [])) < 1:
    errors.append("glb 缺 nodes")
if len(j.get("meshes", [])) < 1:
    errors.append("glb 缺 meshes")
if len(j.get("cameras", [])) < 1:
    errors.append("glb 缺 cameras（光照/相机应随场景导出）")
if "KHR_lights_punctual" not in j.get("extensionsUsed", []):
    errors.append("glb 缺 KHR_lights_punctual 扩展（太阳光应随场景导出）")

# layout 与 FBX 名一致 + lighting/camera 实际值
layout = json.load(open(layout_path))
root = layout.get("root")
groups = [g["name"] for g in layout.get("groups", [])]
names = {n.get("name") for n in j.get("nodes", [])}
if root not in names:
    errors.append(f"layout root '{root}' 不在 glb 节点中")
for g in groups:
    if g not in names:
        errors.append(f"layout group '{g}' 不在 glb 节点中")

lighting = layout.get("lighting", {})
directional = lighting.get("directional", {})
if not isinstance(directional.get("intensity"), (int, float)) or directional.get("intensity") <= 0:
    errors.append("layout.lighting.directional.intensity 不是正值")
if not isinstance(directional.get("rotation"), list) or len(directional.get("rotation", [])) != 3:
    errors.append("layout.lighting.directional.rotation 缺 3 值")

camera = layout.get("camera", {})
if not isinstance(camera.get("position"), list) or len(camera.get("position", [])) != 3:
    errors.append("layout.camera.position 缺 3 值")
if not isinstance(camera.get("lookAt"), list) or len(camera.get("lookAt", [])) != 3:
    errors.append("layout.camera.lookAt 缺 3 值")

if errors:
    print("GLB_LAYOUT_FAIL: " + "; ".join(errors))
    sys.exit(1)
print(f"GLB_LAYOUT_OK: glb nodes={len(j['nodes'])} meshes={len(j['meshes'])} root={root} groups={groups}")
PY
if [ $? -eq 0 ]; then ok "glb + layout 验证通过"; else bad "glb + layout 验证失败"; fi

echo "[5] 汇总"
echo "  产物字节数：blend=$BLEND_BYTES glb=$(wc -c <"$WORK/scene.glb") fbx=$(wc -c <"$WORK/scene.fbx") layout=$(wc -c <"$WORK/layout.json")"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "verify-blender-export.sh：全部通过 ✅"
  exit 0
else
  echo "verify-blender-export.sh：有 $FAIL 项失败 ❌"
  exit 1
fi
