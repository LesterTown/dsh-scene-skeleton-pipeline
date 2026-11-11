#!/usr/bin/env bash
# 材质映射验收（块 D）：asset-library.json 的 9 个材质 key 配 albedo/normal/roughness/metallic 贴图，
# _material(key) 在贴图存在时创建带 Image Texture 的 Principled BSDF，缺失时回退纯色。
#
# 用法：
#   bash scripts/verify/verify-material-mapping.sh              # 全量（含 SuperPBR 共存，若节点可用）
#   bash scripts/verify/verify-material-mapping.sh --skip-llm   # 跳过与真实模型/贴图节点相关的段落
#
# 覆盖：
#   [1] fixture 贴图存在且可被 Blender 读取
#   [2] 未配置 assetLibraryPath：summary.materialMapping.enabled=false，blend 里 LLM_stone 走纯色 fallback
#   [3] 配置 assetLibraryPath：LLM_stone 的 Base Color/Roughness/Normal 连到 Image Texture，material_source=library
#   [4] 部分贴图缺失：删掉 normal（保留 albedo）后该 key 仍是 library，缺的通道（normal）逐项回退
#   [5] 与 SuperPBR 共存：被覆盖对象用 LLM_<id>_pbr，未被覆盖对象仍用 LLM_<key>（材质映射生效）
#   [6] 回归：verify-texture.sh --skip-texture、verify-layout-types.sh --skip-llm、
#       verify-layout-validation.sh --skip-llm、verify-layout-llm.sh
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
BLENDER="${DSH_BLENDER_EXE:-/Applications/Blender.app/Contents/MacOS/Blender}"
COMFY_URL="${DSH_COMFY_URL:-http://127.0.0.1:8188}"
FIXTURES="$PLUGIN_DIR/scripts/verify/fixtures/textures"
WORK="$(mktemp -d /tmp/dsh-matmap-XXXXXX)"
SKIP_LLM=0
[ "${1:-}" = "--skip-llm" ] && SKIP_LLM=1

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
section() { printf '\n== %s ==\n' "$1"; }
check() { if eval "$2" > /dev/null 2>&1; then pass "$1"; else fail "$1" "${3:-}"; fi; }
skip() { printf 'SKIP  %s\n' "$1"; }
jsonq() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1" 2>/dev/null; }

# 开发者面板可能把 .dsh-dev 的本地配置改成 sceneSource=llm / enableTextureGeneration=true，
# 会干扰「未配置」断言；测试期间先备份移走，退出时还原。
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

# ComfyUI 前置：真实链路（comfy 出图 → Blender）必须有 ComfyUI 监听 8188，否则直接给出清晰错误，
# 不再让 real-e2e 静默失败后留下缺失的 last-job.json（那会引发一串 FileNotFoundError）。
COMFY_REACHABLE=0
if [ "$(curl -s --max-time 5 "$COMFY_URL/queue" | head -c 1)" = "{" ]; then
  COMFY_REACHABLE=1
fi
if [ "$COMFY_REACHABLE" = "0" ]; then
  echo "错误：ComfyUI 不可达（$COMFY_URL/queue）。本脚本的真实链路需要 ComfyUI 出图。"
  echo "      请先启动 ComfyUI（端口 8188）再运行；若只做静态检查可用 --skip-llm 之外的其它脚本。"
  exit 2
fi

# 小 plan：stone 材质命中的 column_01（Buildings，main 范围）+ tree_01（Props，材质 trunk/leaf）
cat > "$WORK/plan.json" <<'JSON'
{
  "sceneName": "MaterialTest",
  "bounds": { "width": 20, "depth": 16 },
  "objects": [
    { "id": "column_01", "type": "column", "position": [-4, 0, 2], "size": [0.8, 3.5, 0.8] },
    { "id": "tree_01", "type": "tree", "position": [4, 0, 3], "size": [3, 5, 3] }
  ]
}
JSON

# SuperPBR 共存：column_01 被贴图覆盖（Buildings + main），statue_01 不被覆盖（Props）但仍用 stone
cat > "$WORK/plan-superpbr.json" <<'JSON'
{
  "sceneName": "MaterialSuperPBR",
  "bounds": { "width": 20, "depth": 16 },
  "objects": [
    { "id": "column_01", "type": "column", "position": [-4, 0, 2], "size": [0.8, 3.5, 0.8] },
    { "id": "statue_01", "type": "statue", "position": [4, 0, 2], "size": [1.2, 3, 1.2] }
  ]
}
JSON

# 提取 blend 里的材质图（base/rough/normal 连接类型、material_source、贴图名）与对象→材质映射
cat > "$WORK/inspect.py" <<'PY'
import bpy, json, sys

argv = sys.argv[sys.argv.index('--') + 1:]
out_path = argv[0]
blend_path = argv[1]
bpy.ops.wm.open_mainfile(filepath=blend_path)
materials = {}
for mat in bpy.data.materials:
    if not mat.name.startswith('LLM_') or not mat.use_nodes:
        continue
    nodes = mat.node_tree.nodes
    bsdf = nodes.get('Principled BSDF')
    def link_type(socket_name):
        if bsdf is None:
            return 'none'
        links = bsdf.inputs[socket_name].links
        return links[0].from_node.type if links else 'constant'
    images = sorted({n.image.name for n in nodes if n.type == 'TEX_IMAGE' and n.image})
    materials[mat.name] = {
        'source': mat.get('material_source', ''),
        'base': link_type('Base Color'),
        'rough': link_type('Roughness'),
        'metallic': link_type('Metallic'),
        'normal': link_type('Normal'),
        'images': images,
    }

objects = {}
for obj in bpy.data.objects:
    if obj.type != 'MESH' or not obj.data.materials:
        continue
    names = [m.name for m in obj.data.materials if m]
    if names:
        objects[obj.name] = names
        parent = obj.parent
        if parent is not None:
            objects.setdefault(parent.name, [])
            for name in names:
                if name not in objects[parent.name]:
                    objects[parent.name].append(name)

with open(out_path, 'w', encoding='utf8') as handle:
    json.dump({'materials': materials, 'objects': objects}, handle, ensure_ascii=False)
print('INSPECT_OK')
PY

# 跑一次 llm 模式的真实流水线（Blender 阶段），输出 last-job.json
run_e2e() { # outdir plan_path asset_library
  local outdir="$1" plan="$2" libpath="$3"
  local attempt rc
  mkdir -p "$outdir"
  for attempt in 1 2; do
    DSH_SCENE_SOURCE=llm DSH_LAYOUT_OBJECTS="$plan" DSH_ASSET_LIBRARY="$libpath" \
      node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" "" "$outdir" "material mapping test" scenic \
      > "$outdir/run.log" 2>&1
    rc=$?
    [ "$rc" = "0" ] && break
    echo "  （real-e2e 第 $attempt 次失败，重试一次）" >&2
    sleep 5
  done
  echo "$rc"
}

# 提取 blend（从 job 里取 blender 阶段的 blend 路径）并检查材质图
inspect_blend() { # job_json out_json
  local job="$1" out="$2"
  local blend
  if [ ! -f "$job" ]; then
    return 1
  fi
  blend="$(python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(j['artifacts']['blend'] or '')" "$job" 2>/dev/null)"
  if [ -z "$blend" ] || [ ! -f "$blend" ]; then
    return 1
  fi
  "$BLENDER" --background --factory-startup --python "$WORK/inspect.py" -- "$out" "$blend" > "$WORK/inspect.log" 2>&1 || return 1
  grep -q INSPECT_OK "$WORK/inspect.log"
}

section "1. fixture 贴图"
check "fixture albedo/normal/roughness/metallic 四张都在" "[ -f '$FIXTURES/stone/albedo.png' ] && [ -f '$FIXTURES/stone/normal.png' ] && [ -f '$FIXTURES/stone/roughness.png' ] && [ -f '$FIXTURES/stone/metallic.png' ]"
check "fixture 是合法 PNG（magic）" "python3 -c \"import sys; data=open('$FIXTURES/stone/albedo.png','rb').read(8); sys.exit(0 if data==b'\\x89PNG\\r\\n\\x1a\\n' else 1)\""
check "asset-library.json 9 个材质都声明了 albedoPath" "python3 -c \"
import json, sys
d=json.load(open('$PLUGIN_DIR/lib/asset-library.json'))
mats=d['materials']
ok=len(mats)==9 and all('albedoPath' in v and v['albedoPath'] for v in mats.values())
sys.exit(0 if ok else 1)\""

section "2. 未配置 assetLibraryPath（纯色 fallback）"
OUT_OFF="$WORK/off"
RC="$(run_e2e "$OUT_OFF" "$WORK/plan.json" "")"
check "unconfigured: real-e2e 退出码 0" "[ '$RC' = '0' ]"
check "unconfigured: job done" "jsonq '$OUT_OFF/last-job.json' \"d['status']=='done'\""
check "unconfigured: artifacts.blend 非空" "jsonq '$OUT_OFF/last-job.json' \"bool(d['artifacts']['blend'])\""
check "unconfigured: summary.materialMapping.enabled=false" "jsonq '$OUT_OFF/last-job.json' \"d['summary']['materialMapping']['enabled'] is False\""
check "unconfigured: keysWithTextures 为空" "jsonq '$OUT_OFF/last-job.json' \"d['summary']['materialMapping']['keysWithTextures']==[]\""
if inspect_blend "$OUT_OFF/last-job.json" "$OUT_OFF/materials.json"; then
  pass "unconfigured: blend 可解析"
  check "unconfigured: LLM_stone 走 fallback" "jsonq '$OUT_OFF/materials.json' \"d['materials']['LLM_stone']['source']=='fallback'\""
  check "unconfigured: LLM_stone 的 Base Color 是常量（无贴图）" "jsonq '$OUT_OFF/materials.json' \"d['materials']['LLM_stone']['base']=='constant'\""
  check "unconfigured: LLM_stone 没有贴图节点" "jsonq '$OUT_OFF/materials.json' \"d['materials']['LLM_stone']['images']==[]\""
else
  fail "unconfigured: blend 可解析"
fi

section "3. 配置 assetLibraryPath（材质映射生效）"
OUT_ON="$WORK/on"
RC="$(run_e2e "$OUT_ON" "$WORK/plan.json" "$FIXTURES")"
check "configured: real-e2e 退出码 0" "[ '$RC' = '0' ]"
check "configured: job done" "jsonq '$OUT_ON/last-job.json' \"d['status']=='done'\""
check "configured: summary.materialMapping.enabled=true" "jsonq '$OUT_ON/last-job.json' \"d['summary']['materialMapping']['enabled'] is True\""
check "configured: assetLibraryPath 回写正确" "jsonq '$OUT_ON/last-job.json' \"d['summary']['materialMapping']['assetLibraryPath'].endswith('/fixtures/textures')\""
check "configured: keysWithTextures 含 stone" "jsonq '$OUT_ON/last-job.json' \"'stone' in d['summary']['materialMapping']['keysWithTextures']\""
check "configured: keysFallback 含 trunk 与 leaf（fixture 未提供）" "jsonq '$OUT_ON/last-job.json' \"{'trunk','leaf'} <= set(d['summary']['materialMapping']['keysFallback'])\""
if inspect_blend "$OUT_ON/last-job.json" "$OUT_ON/materials.json"; then
  pass "configured: blend 可解析"
  check "configured: LLM_stone 来源 library" "jsonq '$OUT_ON/materials.json' \"d['materials']['LLM_stone']['source']=='library'\""
  check "configured: Base Color 连 Image Texture" "jsonq '$OUT_ON/materials.json' \"d['materials']['LLM_stone']['base']=='TEX_IMAGE'\""
  check "configured: Roughness 连 Image Texture" "jsonq '$OUT_ON/materials.json' \"d['materials']['LLM_stone']['rough']=='TEX_IMAGE'\""
  check "configured: Metallic 连 Image Texture" "jsonq '$OUT_ON/materials.json' \"d['materials']['LLM_stone']['metallic']=='TEX_IMAGE'\""
  check "configured: Normal 连 Normal Map" "jsonq '$OUT_ON/materials.json' \"d['materials']['LLM_stone']['normal']=='NORMAL_MAP'\""
  check "configured: 四张贴图都加载了" "jsonq '$OUT_ON/materials.json' \"set(d['materials']['LLM_stone']['images']) >= {'albedo.png','normal.png','roughness.png','metallic.png'}\""
  check "configured: tree 的材质仍是 fallback" "jsonq '$OUT_ON/materials.json' \"d['materials']['LLM_trunk']['source']=='fallback'\""
else
  fail "configured: blend 可解析"
fi

section "4. 部分贴图缺失（normal 没了 → 该 key 仍是 library，缺的通道逐项回退）"
PARTIAL="$WORK/partial"
mkdir -p "$PARTIAL/stone"
cp "$FIXTURES/stone/albedo.png" "$FIXTURES/stone/roughness.png" "$FIXTURES/stone/metallic.png" "$PARTIAL/stone/"
OUT_PART="$WORK/partial-out"
RC="$(run_e2e "$OUT_PART" "$WORK/plan.json" "$PARTIAL")"
check "partial: real-e2e 退出码 0" "[ '$RC' = '0' ]"
check "partial: stone 在 keysWithTextures（albedo 存在）" "jsonq '$OUT_PART/last-job.json' \"'stone' in d['summary']['materialMapping']['keysWithTextures']\""
check "partial: stone 不在 keysFallback" "jsonq '$OUT_PART/last-job.json' \"'stone' not in d['summary']['materialMapping']['keysFallback']\""
if inspect_blend "$OUT_PART/last-job.json" "$OUT_PART/materials.json"; then
  check "partial: LLM_stone 来源 library" "jsonq '$OUT_PART/materials.json' \"d['materials']['LLM_stone']['source']=='library'\""
  check "partial: Base Color 仍连贴图" "jsonq '$OUT_PART/materials.json' \"d['materials']['LLM_stone']['base']=='TEX_IMAGE'\""
  check "partial: Roughness 仍连贴图" "jsonq '$OUT_PART/materials.json' \"d['materials']['LLM_stone']['rough']=='TEX_IMAGE'\""
  check "partial: Metallic 仍连贴图" "jsonq '$OUT_PART/materials.json' \"d['materials']['LLM_stone']['metallic']=='TEX_IMAGE'\""
  check "partial: Normal 回退常量（无 normal 贴图）" "jsonq '$OUT_PART/materials.json' \"d['materials']['LLM_stone']['normal']=='constant'\""
else
  fail "partial: blend 可解析"
fi

section "5. 与 SuperPBR 共存"
NODES_OK="$(curl -s --max-time 5 "$COMFY_URL/object_info/SuperPBRModelLoader" | head -c 1)"
if [ "$SKIP_LLM" = "1" ]; then
  skip "SuperPBR 共存：--skip-llm 跳过"
elif [ "$NODES_OK" != "{" ]; then
  skip "SuperPBR 共存：ComfyUI 节点不可用"
else
  OUT_SUPER="$WORK/superpbr"
  mkdir -p "$OUT_SUPER"
  DSH_ENABLE_TEXTURE=1 DSH_TEXTURE_OBJECTS=main DSH_SCENE_SOURCE=llm \
    DSH_LAYOUT_OBJECTS="$WORK/plan-superpbr.json" DSH_ASSET_LIBRARY="$FIXTURES" \
    node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" "" "$OUT_SUPER" \
    "material mapping + superpbr test" scenic > "$OUT_SUPER/run.log" 2>&1
  RC=$?
  check "coexist: real-e2e 退出码 0" "[ '$RC' = '0' ]"
  check "coexist: job done" "jsonq '$OUT_SUPER/last-job.json' \"d['status']=='done'\""
  check "coexist: SuperPBR 至少覆盖 1 个对象" "jsonq '$OUT_SUPER/last-job.json' \"d['summary']['texture']['enabled'] is True and d['summary']['texture']['objectCount'] >= 1\""
  check "coexist: 材质映射同时生效" "jsonq '$OUT_SUPER/last-job.json' \"d['summary']['materialMapping']['enabled'] is True\""
  if inspect_blend "$OUT_SUPER/last-job.json" "$OUT_SUPER/materials.json"; then
    check "coexist: 被覆盖对象用 LLM_column_01_pbr" "jsonq '$OUT_SUPER/materials.json' \"'LLM_column_01_pbr' in d['materials']\""
    check "coexist: 未被覆盖的 statue 仍用 LLM_stone（library）" "jsonq '$OUT_SUPER/materials.json' \"d['materials']['LLM_stone']['source']=='library' and 'LLM_stone' in d['objects'].get('statue_01', [])\""
    check "coexist: Ground 用 LLM_Ground_pbr 或被覆盖材质" "jsonq '$OUT_SUPER/materials.json' \"'LLM_Ground_pbr' in d['materials']\""
  else
    fail "coexist: blend 可解析"
  fi
fi

section "6. 回归"
bash "$PLUGIN_DIR/scripts/verify/verify-texture.sh" --skip-texture > "$WORK/reg-texture.log" 2>&1
check "回归 verify-texture.sh --skip-texture" "[ $? -eq 0 ]"
bash "$PLUGIN_DIR/scripts/verify/verify-layout-types.sh" --skip-llm > "$WORK/reg-types.log" 2>&1
check "回归 verify-layout-types.sh --skip-llm" "[ $? -eq 0 ]"
bash "$PLUGIN_DIR/scripts/verify/verify-layout-validation.sh" --skip-llm > "$WORK/reg-validation.log" 2>&1
check "回归 verify-layout-validation.sh --skip-llm" "[ $? -eq 0 ]"
bash "$PLUGIN_DIR/scripts/verify/verify-layout-llm.sh" > "$WORK/reg-llm.log" 2>&1
check "回归 verify-layout-llm.sh" "[ $? -eq 0 ]"

printf '\n==============================================\n'
printf 'material-mapping: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
