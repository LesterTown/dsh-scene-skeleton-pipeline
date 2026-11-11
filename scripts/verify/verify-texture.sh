#!/usr/bin/env bash
# SuperPBR 贴图生成验收（块 C）：工作流结构 + 关闭模式 + 节点缺失降级 + 真实贴图 + 回归
#
# 用法：
#   bash scripts/verify/verify-texture.sh              # 全量
#   bash scripts/verify/verify-texture.sh --skip-llm   # 跳过真实贴图生成（只做结构/关闭/降级/回归）
#
# 覆盖：
#   [1] 工作流 JSON：pbr-superpbr.json 存在、可解析、节点齐（SuperPBR/MoGe/SaveImage）、含 __ID__ 占位
#   [2] 关闭模式：enableTextureGeneration=false → job done、artifacts.textures=null、summary.texture.enabled=false
#   [3] 缺节点降级：ComfyUI 节点信息不可用 → 贴图阶段写 SKIP 错误、主产物照常产出、exit 0（不崩溃）
#   [4] 真实贴图（节点与模型齐全时）：main 范围 3 个对象 → 贴图文件、blend 里 LLM_<id>_pbr 材质、原材质被替换
#   [5] 回归：verify-layout-validation.sh --skip-llm、verify-layout-types.sh --skip-llm、verify-layout-llm.sh
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
BLENDER="${DSH_BLENDER_EXE:-/Applications/Blender.app/Contents/MacOS/Blender}"
COMFY_URL="${DSH_COMFY_URL:-http://127.0.0.1:8188}"
WORK="$(mktemp -d /tmp/dsh-texture-XXXXXX)"
SKIP_LLM=0
[ "${1:-}" = "--skip-llm" ] && SKIP_LLM=1
SKIP_TEXTURE=0
[ "${1:-}" = "--skip-texture" ] && SKIP_TEXTURE=1
[ "${2:-}" = "--skip-texture" ] && SKIP_TEXTURE=1

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
section() { printf '\n== %s ==\n' "$1"; }
check() { if eval "$2" > /dev/null 2>&1; then pass "$1"; else fail "$1" "${3:-}"; fi; }
skip() { printf 'SKIP  %s\n' "$1"; }

# 开发者面板可能把 .dsh-dev 的本地配置改成 sceneSource=llm/enableTextureGeneration=true，
# 会干扰「关闭模式」断言；测试期间先备份移走，退出时还原。
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
  rm -rf "$WORK"
}
trap cleanup EXIT

# 小 plan：main 范围命中 Ground + column_01 + wall_01（tree_01 属于 Props，不在 main 范围）
cat > "$WORK/plan.json" <<'JSON'
{
  "sceneName": "TextureTest",
  "bounds": { "width": 20, "depth": 16 },
  "objects": [
    { "id": "column_01", "type": "column", "position": [-4, 0, 2], "size": [0.8, 3.5, 0.8] },
    { "id": "wall_01", "type": "wall", "position": [0, 0, -6], "size": [6, 2.4, 0.4] },
    { "id": "tree_01", "type": "tree", "position": [5, 0, 3], "size": [3, 5, 3] }
  ]
}
JSON

# ---------------------------------------------------------------------------
section "[0] 前置检查"
if [ ! -x "$BLENDER" ]; then fail "Blender 可执行存在（${BLENDER}）"; exit 1; fi
pass "Blender 可执行存在（${BLENDER}）"
COMFY_OK=0
if curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$COMFY_URL/queue" | grep -q '^200$'; then
  COMFY_OK=1
  pass "ComfyUI 可达（${COMFY_URL}）"
else
  fail "ComfyUI 可达（$COMFY_URL /queue）"
fi

# ---------------------------------------------------------------------------
section "[1] 工作流 JSON 结构"
WF="$PLUGIN_DIR/lib/workflows/pbr-superpbr.json"
check "pbr-superpbr.json 存在" "[ -f \"$WF\" ]"
check "pbr-superpbr-lite.json 存在（无 MoGe 回退）" "[ -f \"$PLUGIN_DIR/lib/workflows/pbr-superpbr-lite.json\" ]"
check "JSON 可解析" "node -e \"JSON.parse(require('fs').readFileSync('$WF','utf8'))\""
check "节点含 LoadImage / SuperPBRModelLoader / SuperPBRDecompose / SuperPBRORMSplit" "node -e \"
const wf=JSON.parse(require('fs').readFileSync('$WF','utf8'));
const classes=Object.values(wf).map(n=>n.class_type);
const need=['LoadImage','SuperPBRModelLoader','SuperPBRDecompose','SuperPBRORMSplit'];
process.exit(need.every(n=>classes.includes(n))?0:1)\""
check "节点含 MoGeInference / LoadMoGeModel / MoGeRender" "node -e \"
const wf=JSON.parse(require('fs').readFileSync('$WF','utf8'));
const classes=Object.values(wf).map(n=>n.class_type);
process.exit(['MoGeInference','LoadMoGeModel','MoGeRender'].every(n=>classes.includes(n))?0:1)\""
check "6 个 SaveImage（albedo/normal/roughness/metallic/ao/height）" "node -e \"
const wf=JSON.parse(require('fs').readFileSync('$WF','utf8'));
const saves=Object.values(wf).filter(n=>n.class_type==='SaveImage');
const prefixes=saves.map(n=>String(n.inputs.filename_prefix));
const kinds=['albedo','normal','roughness','metallic','ao','height'];
process.exit(saves.length>=6 && kinds.every(k=>prefixes.some(p=>p.endsWith(k)))?0:1)\""
check "SaveImage 前缀含 __ID__ 占位" "grep -q '__ID__' \"$WF\""
check "SuperPBRDecompose，ORM Split 输出接 roughness/metallic/ao" "node -e \"
const wf=JSON.parse(require('fs').readFileSync('$WF','utf8'));
const orm=Object.entries(wf).find(([,n])=>n.class_type==='SuperPBRORMSplit');
if(!orm) process.exit(1);
const id=orm[0];
const outs=Object.values(wf).filter(n=>n.class_type==='SaveImage' && Array.isArray(n.inputs.images) && n.inputs.images[0]===id);
process.exit(outs.length>=3?0:1)\""

# ---------------------------------------------------------------------------
section "[2] 关闭模式（enableTextureGeneration=false）"
OUT_OFF="$WORK/off"
if [ "$COMFY_OK" = "1" ]; then
  DSH_SCENE_SOURCE=llm DSH_LAYOUT_OBJECTS="$WORK/plan.json" \
    node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" "" "$OUT_OFF" "a small stone courtyard" scenic > "$WORK/off.log" 2>&1
  OFF_RC=$?
  check "关闭贴图时流水线 exit=0" "[ $OFF_RC -eq 0 ]" "见 $WORK/off.log"
  check "job done" "node -e \"
const j=JSON.parse(require('fs').readFileSync('$OUT_OFF/last-job.json','utf8'));
process.exit(j.status==='done'?0:1)\""
  check "artifacts.textures 为 null" "node -e \"
const j=JSON.parse(require('fs').readFileSync('$OUT_OFF/last-job.json','utf8'));
process.exit(j.artifacts && j.artifacts.textures===null?0:1)\""
  check "summary.texture.enabled === false" "node -e \"
const j=JSON.parse(require('fs').readFileSync('$OUT_OFF/last-job.json','utf8'));
process.exit(j.summary && j.summary.texture && j.summary.texture.enabled===false?0:1)\""
else
  skip "[2] 关闭模式（ComfyUI 不可达，跳过真实流水线）"
fi

# ---------------------------------------------------------------------------
section "[3] 缺节点降级（SKIP 不崩）"
# 起一个假 ComfyUI：/object_info/* 一律 404，模拟未安装 SuperPBR/MoGe 节点
python3 - "$WORK/fake_comfy_port" <<'PY' &
import http.server, socketserver, sys, json
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/object_info'):
            self.send_response(404); self.end_headers(); self.wfile.write(b'{"error":"not found"}')
        else:
            self.send_response(200); self.send_header('content-type','application/json'); self.end_headers()
            self.wfile.write(json.dumps({}).encode())
    def log_message(self, *a): pass
with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    port = httpd.server_address[1]
    open(sys.argv[1], 'w').write(str(port))
    httpd.serve_forever()
PY
FAKE_PID=$!
for i in $(seq 1 50); do [ -s "$WORK/fake_comfy_port" ] && break; sleep 0.1; done
FAKE_PORT="$(cat "$WORK/fake_comfy_port" 2>/dev/null || true)"
if [ -n "$FAKE_PORT" ]; then
  mkdir -p "$WORK/skip"
  "$BLENDER" --background --factory-startup --python "$PLUGIN_DIR/lib/scripts/run_scenic.py" -- \
    "$PLUGIN_DIR/lib/scripts/scenes/courtyard.py" \
    "$WORK/skip/scene.blend" "$WORK/skip/scene.glb" "$WORK/skip/scene.fbx" "$WORK/skip/layout.json" \
    "{\"sceneSource\":\"llm\",\"layoutAxis\":\"y-up\",\"layoutObjects\":\"$WORK/plan.json\",\"texture\":{\"enabled\":true,\"comfyUrl\":\"http://127.0.0.1:$FAKE_PORT\",\"resolution\":256,\"objects\":\"main\",\"workflowPath\":\"$WF\",\"texturesDir\":\"$WORK/skip/textures\",\"timeoutSeconds\":5}}" \
    > "$WORK/skip.log" 2>&1
  SKIP_RC=$?
  check "缺节点时 Blender 仍 exit=0（不崩溃）" "[ $SKIP_RC -eq 0 ]" "见 $WORK/skip.log"
  check "主产物仍产出（.blend/.fbx/.glb/layout.json）" "[ -s \"$WORK/skip/scene.blend\" ] && [ -s \"$WORK/skip/scene.fbx\" ] && [ -s \"$WORK/skip/scene.glb\" ] && [ -s \"$WORK/skip/layout.json\" ]"
  check "结果含 texture.error 且为 SKIP 提示" "grep -q 'DSH_BLENDER_RESULT' \"$WORK/skip.log\" && grep -q 'SKIP: SuperPBR' \"$WORK/skip.log\""
else
  fail "假 ComfyUI 启动（降级测试）"
fi
kill "$FAKE_PID" 2>/dev/null

# ---------------------------------------------------------------------------
section "[4] 真实贴图生成（节点与模型齐全时）"
NODES_OK=0
if [ "$COMFY_OK" = "1" ] && [ "$SKIP_LLM" = "0" ] && [ "$SKIP_TEXTURE" = "0" ]; then
  if curl -s --max-time 5 "$COMFY_URL/object_info/SuperPBRDecompose" | grep -q 'SuperPBRDecompose' \
     && curl -s --max-time 5 "$COMFY_URL/object_info/LoadMoGeModel" | grep -q 'LoadMoGeModel'; then
    NODES_OK=1
  fi
fi
if [ "$NODES_OK" = "1" ]; then
  OUT_ON="$WORK/on"
  DSH_ENABLE_TEXTURE=1 DSH_TEXTURE_RESOLUTION=512 DSH_TEXTURE_OBJECTS=main \
    DSH_SCENE_SOURCE=llm DSH_LAYOUT_OBJECTS="$WORK/plan.json" \
    node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" "" "$OUT_ON" "a small stone courtyard" scenic > "$WORK/on.log" 2>&1
  ON_RC=$?
  check "开启贴图时流水线 exit=0" "[ $ON_RC -eq 0 ]" "见 $WORK/on.log"
  check "job done 且 summary.texture.enabled=true" "node -e \"
const j=JSON.parse(require('fs').readFileSync('$OUT_ON/last-job.json','utf8'));
process.exit(j.status==='done' && j.summary?.texture?.enabled===true?0:1)\""
  check "贴图对象数 > 0 且失败数 = 0" "node -e \"
const j=JSON.parse(require('fs').readFileSync('$OUT_ON/last-job.json','utf8'));
const t=j.summary?.texture||{};
process.exit(t.objectCount>0 && t.failedCount===0?0:1)\""
  TEXTURES_DIR="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(j.artifacts?.textures||"")' "$OUT_ON/last-job.json")"
  check "artifacts.textures 指向贴图目录" "[ -n \"$TEXTURES_DIR\" ] && [ -d \"$TEXTURES_DIR\" ]"
  ALBEDO_COUNT=$(find "$TEXTURES_DIR" -name '*_albedo.png' 2>/dev/null | wc -l | tr -d ' ')
  check "贴图目录含 ≥1 张 albedo" "[ \"${ALBEDO_COUNT:-0}\" -ge 1 ]"

  ROUGH_COUNT=$(find "$TEXTURES_DIR" -name '*_roughness.png' 2>/dev/null | wc -l | tr -d ' ')
  METAL_COUNT=$(find "$TEXTURES_DIR" -name '*_metallic.png' 2>/dev/null | wc -l | tr -d ' ')
  check "贴图目录含 roughness/metallic（normal 依赖 MoGe，可选）" "[ \"${ROUGH_COUNT:-0}\" -ge 1 ] && [ \"${METAL_COUNT:-0}\" -ge 1 ]"
  BLEND_PATH="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(j.artifacts?.blend||"")' "$OUT_ON/last-job.json")"
  cat > "$WORK/inspect-blend.py" <<'PY'
import bpy, sys, json
path = sys.argv[sys.argv.index('--') + 1]
bpy.ops.wm.open_mainfile(filepath=path)
report = {"pbr_materials": [], "base_color_linked": [], "replaced": []}
for material in bpy.data.materials:
    if not material.name.startswith('LLM_') or not material.name.endswith('_pbr'):
        continue
    report["pbr_materials"].append(material.name)
    node = material.node_tree.nodes.get('Principled BSDF')
    if node is not None:
        links = node.inputs['Base Color'].links
        report["base_color_linked"].append(len(links) > 0 and links[0].from_node.type == 'TEX_IMAGE')
for obj in bpy.data.objects:
    if obj.type != 'MESH' or '.' in obj.name:
        continue
    names = [slot.material.name for slot in obj.material_slots if slot.material]
    if any(name.endswith('_pbr') for name in names):
        report["replaced"].append(obj.name)
print('DSH_TEXTURE_REPORT:' + json.dumps(report))
PY
  "$BLENDER" --background --factory-startup --python "$WORK/inspect-blend.py" -- "$BLEND_PATH" > "$WORK/inspect.log" 2>&1
  check "blend 里存在 LLM_<id>_pbr 材质且 Base Color 连 Image Texture" "grep -q 'DSH_TEXTURE_REPORT' \"$WORK/inspect.log\" && node -e \"
const line=require('fs').readFileSync('$WORK/inspect.log','utf8').split('\\n').find(l=>l.includes('DSH_TEXTURE_REPORT'));
const r=JSON.parse(line.slice(line.indexOf(':')+1));
process.exit(r.pbr_materials.length>0 && r.base_color_linked.every(Boolean)?0:1)\""
  check "至少一个网格已换成 pbr 材质（原 LLM_<key> 被替换）" "node -e \"
const line=require('fs').readFileSync('$WORK/inspect.log','utf8').split('\\n').find(l=>l.includes('DSH_TEXTURE_REPORT'));
const r=JSON.parse(line.slice(line.indexOf(':')+1));
process.exit(r.replaced.length>0?0:1)\""
else
  if [ "$SKIP_TEXTURE" = "1" ]; then
    skip "[4] 真实贴图生成（--skip-texture）"
  else
    skip "[4] 真实贴图生成（SuperPBR/MoGe 节点或模型未就绪）"
  fi
fi

# ---------------------------------------------------------------------------
section "[5] 回归"
bash "$PLUGIN_DIR/scripts/verify/verify-layout-validation.sh" --skip-llm > "$WORK/reg-validation.log" 2>&1
check "verify-layout-validation.sh --skip-llm 通过" "[ $? -eq 0 ]"
bash "$PLUGIN_DIR/scripts/verify/verify-layout-types.sh" --skip-llm > "$WORK/reg-types.log" 2>&1
check "verify-layout-types.sh --skip-llm 通过" "[ $? -eq 0 ]"
if [ "$SKIP_LLM" = "0" ] && [ "$COMFY_OK" = "1" ]; then
  bash "$PLUGIN_DIR/scripts/verify/verify-layout-llm.sh" > "$WORK/reg-llm.log" 2>&1
  check "verify-layout-llm.sh 通过" "[ $? -eq 0 ]"
else
  skip "[5] verify-layout-llm.sh（跳过真实模型）"
fi

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'texture: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
