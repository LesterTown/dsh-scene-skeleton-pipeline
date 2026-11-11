#!/usr/bin/env bash
# 几何模型映射验收（块 E）：asset-library.json 里每个 type 可选 modelPath（相对 assetModelPath），
# 存在则导入真实 .glb/.gltf 并「Join 合并 + 底部中心对齐原点 + 等比缩放（高度为主，不拉伸）」，
# 否则回退程序化图元。
#
# 用法：
#   bash scripts/verify/verify-geometry-mapping.sh              # 全量
#   bash scripts/verify/verify-geometry-mapping.sh --skip-llm   # 跳过真实模型段的 ComfyUI 前置（仍会跑 Blender）
#
# 覆盖：
#   [1] fixture 模型存在且是合法 glb + 每个 type 有 modelPath/license/sourceUrl
#   [2] 未配置 assetModelPath：2 对象（tree+column）全 asset_source="primitive"
#   [3] 全量回退：18 种 type 未配置资产 → 全部 primitive、无 Blender 报错（模拟 clone 后状态）
#   [4] 配置 assetModelPath：tree 用真实模型（asset_source="model"、底部对齐地面、等比缩放高度匹配 plan）、
#       column 无 modelPath 回退 primitive
#   [5] 回归：verify-material-mapping.sh --skip-llm、verify-texture.sh --skip-texture
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
BLENDER="${DSH_BLENDER_EXE:-/Applications/Blender.app/Contents/MacOS/Blender}"
COMFY_URL="${DSH_COMFY_URL:-http://127.0.0.1:8188}"
MODELS="$PLUGIN_DIR/scripts/verify/fixtures/models"
WORK="$(mktemp -d /tmp/dsh-geomap-XXXXXX)"
SKIP_LLM=0
[ "${1:-}" = "--skip-llm" ] && SKIP_LLM=1

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
section() { printf '\n== %s ==\n' "$1"; }
check() { if eval "$2" > /dev/null 2>&1; then pass "$1"; else fail "$1" "${3:-}"; fi; }
jsonq() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1" 2>/dev/null; }

# 开发者面板可能把 .dsh-dev 的本地配置改掉，干扰「未配置」断言；测试期间备份移走，退出还原。
CONFIG_FILE="$ROOT/.dsh-dev/scene-skeleton-pipeline/config.json"
CONFIG_BAK=""
if [ -f "$CONFIG_FILE" ]; then
  CONFIG_BAK="$WORK/config.json.bak"
  cp "$CONFIG_FILE" "$CONFIG_BAK"
  rm -f "$CONFIG_FILE"
fi

cleanup() {
  if [ -n "$CONFIG_BAK" ] && [ -f "$CONFIG_BAK" ]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cp "$CONFIG_BAK" "$CONFIG_FILE"
  fi
  [ "${KEEP_WORK:-0}" = "1" ] || rm -rf "$WORK"
}
trap cleanup EXIT

# 小 plan：tree_01 命中 modelPath（fixture），column_01 无 modelPath（回退 primitive）
cat > "$WORK/plan.json" <<'JSON'
{
  "sceneName": "GeometryTest",
  "bounds": { "width": 20, "depth": 16 },
  "objects": [
    { "id": "tree_01", "type": "tree", "position": [-4, 0, 2], "size": [3, 5, 3] },
    { "id": "column_01", "type": "column", "position": [4, 0, 2], "size": [0.8, 3.5, 0.8] }
  ]
}
JSON

# 全量回退 plan：从 asset-library.json 读全部 18 种 type，按默认尺寸放到 6×3 网格（不重叠、贴地、界内）。
python3 - "$PLUGIN_DIR/lib/asset-library.json" "$WORK/plan-all.json" <<'PY'
import json, sys
lib = json.load(open(sys.argv[1]))
types = [a["type"] for a in lib["assets"]]
defaults = {a["type"]: a["defaultSize"] for a in lib["assets"]}
cols, rows = 6, 3
sx, sz = 6.0, 7.0
objects = []
for i, t in enumerate(types):
    col = i % cols
    row = i // cols
    x = round((col - (cols - 1) / 2.0) * sx, 2)
    z = round((row - (rows - 1) / 2.0) * sz, 2)
    objects.append({
        "id": f"{t}_01",
        "type": t,
        "position": [x, 0, z],
        "size": defaults[t],
    })
plan = {"sceneName": "AllTypes", "bounds": {"width": 44, "depth": 28}, "objects": objects}
json.dump(plan, open(sys.argv[2], "w"), ensure_ascii=False)
print(f"plan-all: {len(objects)} objects")
PY

# 打开 blend，输出每个 plan 对象的 asset_source + 其 mesh 子节点的世界包围盒（z 最小/最大、长宽高）
cat > "$WORK/inspect.py" <<'PY'
import bpy, json, sys
from mathutils import Vector

argv = sys.argv[sys.argv.index('--') + 1:]
out_path = argv[0]
blend_path = argv[1]
bpy.ops.wm.open_mainfile(filepath=blend_path)
result = {}
for name in ('tree_01', 'column_01'):
    obj = bpy.data.objects.get(name)
    if obj is None:
        result[name] = {'source': 'missing'}
        continue
    meshes = [c for c in obj.children_recursive if c.type == 'MESH']
    if not meshes:
        result[name] = {'source': str(obj.get('asset_source', '')), 'meshes': 0}
        continue
    xs, ys, zs = [], [], []
    for m in meshes:
        for corner in m.bound_box:
            p = m.matrix_world @ Vector(tuple(corner))
            xs.append(p.x); ys.append(p.y); zs.append(p.z)
    result[name] = {
        'source': str(obj.get('asset_source', '')),
        'meshes': len(meshes),
        'zmin': round(min(zs), 4),
        'zmax': round(max(zs), 4),
        'height': round(max(zs) - min(zs), 4),
        'width': round(max(xs) - min(xs), 4),
        'depth': round(max(ys) - min(ys), 4),
    }
with open(out_path, 'w', encoding='utf8') as handle:
    json.dump(result, handle, ensure_ascii=False)
print('INSPECT_OK')
PY

# 打开 blend，按 plan-all.json 的对象 id 逐个读 asset_source，汇总 primitive/model/missing 计数
cat > "$WORK/inspect-all.py" <<'PY'
import bpy, json, sys
argv = sys.argv[sys.argv.index('--') + 1:]
out_path, blend_path, plan_path = argv[0], argv[1], argv[2]
bpy.ops.wm.open_mainfile(filepath=blend_path)
plan = json.load(open(plan_path))
primitive = model = missing = 0
detail = {}
for o in plan["objects"]:
    name = o["id"]
    obj = bpy.data.objects.get(name)
    src = str(obj.get("asset_source", "")) if obj is not None else "missing"
    detail[name] = src
    if src == "primitive":
        primitive += 1
    elif src == "model":
        model += 1
    else:
        missing += 1
with open(out_path, 'w', encoding='utf8') as handle:
    json.dump({"primitive": primitive, "model": model, "missing": missing, "detail": detail},
              handle, ensure_ascii=False)
print('INSPECT_ALL_OK')
PY

run_e2e() { # outdir asset_model_path [plan_path]
  local outdir="$1" modelpath="$2" plan="${3:-$WORK/plan.json}"
  mkdir -p "$outdir"
  DSH_SCENE_SOURCE=llm DSH_LAYOUT_OBJECTS="$plan" DSH_ASSET_MODEL="$modelpath" \
    node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" "" "$outdir" "geometry mapping test" scenic \
    > "$outdir/run.log" 2>&1
  echo $?
}

inspect_blend() { # job_json out_json
  local job="$1" out="$2"
  if [ ! -f "$job" ]; then return 1; fi
  local blend
  blend="$(python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(j['artifacts']['blend'] or '')" "$job" 2>/dev/null)"
  if [ -z "$blend" ] || [ ! -f "$blend" ]; then return 1; fi
  "$BLENDER" --background --factory-startup --python "$WORK/inspect.py" -- "$out" "$blend" > "$WORK/inspect.log" 2>&1 || return 1
  grep -q INSPECT_OK "$WORK/inspect.log"
}

inspect_blend_all() { # job_json out_json plan_json
  local job="$1" out="$2" plan="$3"
  if [ ! -f "$job" ]; then return 1; fi
  local blend
  blend="$(python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(j['artifacts']['blend'] or '')" "$job" 2>/dev/null)"
  if [ -z "$blend" ] || [ ! -f "$blend" ]; then return 1; fi
  "$BLENDER" --background --factory-startup --python "$WORK/inspect-all.py" -- "$out" "$blend" "$plan" > "$WORK/inspect-all.log" 2>&1 || return 1
  grep -q INSPECT_ALL_OK "$WORK/inspect-all.log"
}

section "1. fixture 模型"
check "tree_pine.glb 存在" "[ -f '$MODELS/kenney_nature/tree_pine.glb' ]"
check "tree_pine.glb 是合法 glb（magic glTF）" "python3 -c \"import sys; d=open('$MODELS/kenney_nature/tree_pine.glb','rb').read(4); sys.exit(0 if d==b'glTF' else 1)\""
check "asset-library.json 18 个 type 都有非空 modelPath + license CC0 + sourceUrl" "python3 -c \"
import json, sys
d=json.load(open('$PLUGIN_DIR/lib/asset-library.json'))
assets=d['assets']
ok = len(assets)==18 and all(
    a.get('modelPath') and a.get('license')=='CC0' and str(a.get('sourceUrl','')).startswith('http')
    for a in assets)
sys.exit(0 if ok else 1)\""

section "2. 未配置 assetModelPath（全部程序化图元）"
OUT_OFF="$WORK/off"
RC="$(run_e2e "$OUT_OFF" "")"
check "unconfigured: real-e2e 退出码 0" "[ '$RC' = '0' ]" "见 $OUT_OFF/run.log"
check "unconfigured: summary.geometryMapping.modelsUsed=0" "jsonq '$OUT_OFF/last-job.json' \"d['summary']['geometryMapping']['modelsUsed']==0\""
check "unconfigured: summary.geometryMapping.primitivesFallback=2" "jsonq '$OUT_OFF/last-job.json' \"d['summary']['geometryMapping']['primitivesFallback']==2\""
if inspect_blend "$OUT_OFF/last-job.json" "$OUT_OFF/geo.json"; then
  check "unconfigured: tree_01 asset_source=primitive" "jsonq '$OUT_OFF/geo.json' \"d['tree_01']['source']=='primitive'\""
  check "unconfigured: column_01 asset_source=primitive" "jsonq '$OUT_OFF/geo.json' \"d['column_01']['source']=='primitive'\""
else
  fail "unconfigured: blend 可解析"
fi

section "3. 全量回退（18 种 type，未配置资产 → 全部 primitive）"
OUT_ALL="$WORK/all"
RC="$(run_e2e "$OUT_ALL" "" "$WORK/plan-all.json")"
check "allfallback: real-e2e 退出码 0" "[ '$RC' = '0' ]" "见 $OUT_ALL/run.log"
check "allfallback: modelsUsed=0" "jsonq '$OUT_ALL/last-job.json' \"d['summary']['geometryMapping']['modelsUsed']==0\""
check "allfallback: primitivesFallback=18" "jsonq '$OUT_ALL/last-job.json' \"d['summary']['geometryMapping']['primitivesFallback']==18\""
if inspect_blend_all "$OUT_ALL/last-job.json" "$OUT_ALL/geo-all.json" "$WORK/plan-all.json"; then
  check "allfallback: 18 个对象全部 primitive（无 model/missing）" "jsonq '$OUT_ALL/geo-all.json' \"d['primitive']==18 and d['model']==0 and d['missing']==0\""
else
  fail "allfallback: blend 可解析"
fi

section "4. 配置 assetModelPath（tree 用真实模型，column 回退）"
OUT_ON="$WORK/on"
RC="$(run_e2e "$OUT_ON" "$MODELS")"
check "configured: real-e2e 退出码 0" "[ '$RC' = '0' ]" "见 $OUT_ON/run.log"
check "configured: modelsUsed=1" "jsonq '$OUT_ON/last-job.json' \"d['summary']['geometryMapping']['modelsUsed']==1\""
check "configured: primitivesFallback=1" "jsonq '$OUT_ON/last-job.json' \"d['summary']['geometryMapping']['primitivesFallback']==1\""
if inspect_blend "$OUT_ON/last-job.json" "$OUT_ON/geo.json"; then
  check "configured: tree_01 asset_source=model" "jsonq '$OUT_ON/geo.json' \"d['tree_01']['source']=='model'\""
  check "configured: tree_01 底部对齐地面（zmin≈0，容差 0.05）" "jsonq '$OUT_ON/geo.json' \"abs(d['tree_01']['zmin']) < 0.05\""
  check "configured: tree_01 高度匹配 plan（5m，容差 0.05）" "jsonq '$OUT_ON/geo.json' \"abs(d['tree_01']['height']-5.0) < 0.05\""
  check "configured: tree_01 等比缩放（宽≈高，容差 0.05）" "jsonq '$OUT_ON/geo.json' \"abs(d['tree_01']['width']-d['tree_01']['height']) < 0.05\""
  check "configured: column_01 回退 primitive" "jsonq '$OUT_ON/geo.json' \"d['column_01']['source']=='primitive'\""
else
  fail "configured: blend 可解析"
fi

section "5. 回归"
bash "$PLUGIN_DIR/scripts/verify/verify-material-mapping.sh" --skip-llm > "$WORK/reg-mat.log" 2>&1
check "回归 verify-material-mapping.sh --skip-llm" "[ $? -eq 0 ]" "见 $WORK/reg-mat.log"
if [ "$SKIP_LLM" = "0" ]; then
  bash "$PLUGIN_DIR/scripts/verify/verify-texture.sh" --skip-texture > "$WORK/reg-tex.log" 2>&1
  check "回归 verify-texture.sh --skip-texture" "[ $? -eq 0 ]" "见 $WORK/reg-tex.log"
fi

printf '\n==============================================\n'
printf 'geometry-mapping: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
