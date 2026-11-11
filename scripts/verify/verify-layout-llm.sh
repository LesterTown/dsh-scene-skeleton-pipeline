#!/usr/bin/env bash
# ============================================================================
# 阶段 7「LLM 精确布局」验证：文字 → plan（plan_scene_layout）→ 校验 → Blender 精确摆放
# ----------------------------------------------------------------------------
# 用法：
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-layout-llm.sh
#
# 不需要 ComfyUI / Unity，也不需要真的调模型：
#   [1] plan-harness.mjs 单元验收（假 llm）：ok 计划、围栏 JSON、重叠/悬浮/非法输出被拒、savePath 写盘
#   [2] layout_validate.py：合法 plan 通过；重叠 / 悬浮 / 尺寸超限分别被拒
#   [3] run_scenic.py sceneSource=llm 真实跑（显式 layoutAxis=y-up，使 plan 与 layout 坐标一一对应）：
#       4 产物齐全、DSH_BLENDER_RESULT 含 objectCount
#   [4] layout.json 的对象坐标与 plan 完全一致（0.001 容差）
#   [5] scene.fbx 重导入：root / Terrain / Buildings / Props / 全部对象 id 都在，层级正确
#   [6] 非法 plan 让 Blender 拒绝执行（退出码非 0 且错误信息含「布局校验失败」）
#   [7] 宿主接线：插件加载日志含 plan tool registered: plan_scene_layout；/state 配置含 sceneSource/layoutObjects
# ============================================================================
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"

BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
[ -x "$BLENDER" ] || BLENDER="$(command -v blender 2>/dev/null || true)"
if [ -z "$BLENDER" ] || [ ! -x "$BLENDER" ]; then
  echo "FATAL: 找不到 Blender 可执行文件（可 export BLENDER=/path/to/blender）" >&2
  exit 1
fi
# 纯 Python 校验脚本用 Blender 自带解释器跑（不需要 bpy）
BLENDER_PY="$(dirname "$BLENDER")/../Resources/4.5/python/bin/python3.11"
if [ ! -x "$BLENDER_PY" ]; then
  BLENDER_PY="$(dirname "$BLENDER")/../Resources/4.5/python/bin/python3.11"
fi
if [ ! -x "$BLENDER_PY" ]; then
  echo "FATAL: 找不到 Blender 自带 python（${BLENDER_PY}）" >&2
  exit 1
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

WORK="$(mktemp -d /tmp/dsh-layout-llm.XXXXXX)"
HOST_LOG="$WORK/host.log"
HOST_PID=""
# .dsh-dev 里的插件配置是开发者本地状态（可能被面板改成 sceneSource=llm），
# 本脚本要断言「全新安装默认 template」，所以先挪开、结束时还原。
CONFIG_FILE="$ROOT/.dsh-dev/scene-skeleton-pipeline/config.json"
CONFIG_BAK="$WORK/config.json.bak"
if [ -f "$CONFIG_FILE" ]; then cp "$CONFIG_FILE" "$CONFIG_BAK"; fi
rm -f "$CONFIG_FILE"
cleanup() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  if [ -f "$CONFIG_BAK" ]; then mkdir -p "$(dirname "$CONFIG_FILE")"; cp "$CONFIG_BAK" "$CONFIG_FILE"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

cat >"$WORK/plan.json" <<'JSON'
{
  "sceneName": "VerifyLLM",
  "bounds": { "width": 24, "depth": 20 },
  "objects": [
    { "id": "fountain_01", "type": "fountain", "position": [0, 0, 0], "size": [4, 0.8, 4] },
    { "id": "column_01", "type": "column", "position": [-8, 0, -6], "size": [0.8, 3.5, 0.8] },
    { "id": "column_02", "type": "column", "position": [8, 0, -6], "size": [0.8, 3.5, 0.8] },
    { "id": "column_03", "type": "column", "position": [-8, 0, 6], "size": [0.8, 3.5, 0.8] },
    { "id": "column_04", "type": "column", "position": [8, 0, 6], "size": [0.8, 3.5, 0.8] },
    { "id": "tree_01", "type": "tree", "position": [-10, 0, 0], "size": [3, 5, 3] },
    { "id": "tree_02", "type": "tree", "position": [10, 0, 0], "size": [3, 5, 3] },
    { "id": "wall_01", "type": "wall", "position": [0, 0, -8.5], "size": [10, 2.4, 0.4] },
    { "id": "bench_01", "type": "bench", "position": [-4, 0, 5], "size": [2, 0.5, 0.7] },
    { "id": "lantern_01", "type": "lantern", "position": [4, 0, 5], "size": [0.6, 3, 0.6] },
    { "id": "rock_01", "type": "rock", "position": [6, 0, -4], "size": [1.5, 1, 1.5] }
  ]
}
JSON

echo "[1] plan-harness.mjs（假 llm 单元验收）"
if node "$ROOT/scratch-plugin/plan-harness.mjs" >"$WORK/plan-harness.log" 2>&1; then
  ok "plan-harness 全部通过（$(grep -o '[0-9]* passed' "$WORK/plan-harness.log" | tail -1)）"
else
  bad "plan-harness 失败"
  tail -20 "$WORK/plan-harness.log"
fi

echo "[2] layout_validate.py（合法 / 重叠 / 悬浮 / 尺寸超限）"
"$BLENDER_PY" "$PLUGIN_DIR/lib/scripts/layout_validate.py" "$WORK/plan.json" >/dev/null 2>&1
check_eq "合法 plan 通过" "$?" "0"

cat >"$WORK/bad-overlap.json" <<'JSON'
{ "bounds": { "width": 24, "depth": 20 }, "objects": [
  { "id": "a", "type": "column", "position": [0, 0, 0], "size": [1, 3, 1] },
  { "id": "b", "type": "column", "position": [0.3, 0, 0], "size": [1, 3, 1] } ] }
JSON
"$BLENDER_PY" "$PLUGIN_DIR/lib/scripts/layout_validate.py" "$WORK/bad-overlap.json" >/dev/null 2>"$WORK/overlap.err"
check_eq "重叠 plan 被拒（exit=1）" "$?" "1"
check "重叠错误信息可读" "grep -q '重叠' '$WORK/overlap.err'"

cat >"$WORK/bad-float.json" <<'JSON'
{ "objects": [ { "id": "a", "type": "column", "position": [0, 2, 0], "size": [1, 3, 1] } ] }
JSON
"$BLENDER_PY" "$PLUGIN_DIR/lib/scripts/layout_validate.py" "$WORK/bad-float.json" >/dev/null 2>"$WORK/float.err"
check_eq "悬浮 plan 被拒（exit=1）" "$?" "1"
check "悬浮错误信息可读" "grep -q '悬浮' '$WORK/float.err'"

cat >"$WORK/bad-size.json" <<'JSON'
{ "objects": [ { "id": "a", "type": "column", "position": [0, 0, 0], "size": [1, 0.2, 1] } ] }
JSON
"$BLENDER_PY" "$PLUGIN_DIR/lib/scripts/layout_validate.py" "$WORK/bad-size.json" >/dev/null 2>"$WORK/size.err"
check_eq "尺寸超限 plan 被拒（exit=1）" "$?" "1"
check "尺寸错误信息可读" "grep -q '超出' '$WORK/size.err'"

echo "[3] run_scenic.py sceneSource=llm 真实跑"
"$BLENDER" --background --factory-startup \
  --python "$PLUGIN_DIR/lib/scripts/run_scenic.py" -- \
  "$PLUGIN_DIR/lib/scripts/scenes/courtyard.py" \
  "$WORK/scene.blend" "$WORK/scene.glb" "$WORK/scene.fbx" "$WORK/layout.json" \
  "{\"sceneSource\":\"llm\",\"layoutObjects\":\"$WORK/plan.json\",\"layoutAxis\":\"y-up\"}" >"$WORK/blender.log" 2>&1
check_eq "run_scenic.py 退出码 0" "$?" "0"
check "日志含 DSH_BLENDER_RESULT" "grep -q 'DSH_BLENDER_RESULT' '$WORK/blender.log'"
check "mode=llm" "grep -q '\"mode\": \"llm\"' '$WORK/blender.log'"
RESULT_LINE=$(grep 'DSH_BLENDER_RESULT:' "$WORK/blender.log" | tail -1)
OBJECT_COUNT=$(printf '%s' "$RESULT_LINE" | sed 's/.*"objectCount": \([0-9]*\).*/\1/')
check_eq "objectCount=12（11 个对象 + 1 个地面）" "$OBJECT_COUNT" "12"
check "scene.blend 非空" "[ -s '$WORK/scene.blend' ]"
check "scene.fbx 非空" "[ -s '$WORK/scene.fbx' ]"
check "scene.glb 非空" "[ -s '$WORK/scene.glb' ]"

echo "[4] layout.json 坐标与 plan 一致"
cat >"$WORK/check-layout.mjs" <<'JS'
import { readFileSync } from 'node:fs'
const [layoutPath, planPath] = process.argv.slice(2)
const layout = JSON.parse(readFileSync(layoutPath, 'utf8'))
const plan = JSON.parse(readFileSync(planPath, 'utf8'))
const byName = {}
for (const group of layout.groups) for (const object of group.objects) byName[object.instanceName] = object
let bad = 0
for (const spec of plan.objects) {
  const placed = byName[spec.id]
  if (!placed) { console.log(`MISSING ${spec.id}`); bad += 1; continue }
  for (let index = 0; index < 3; index += 1) {
    if (Math.abs(placed.position[index] - spec.position[index]) > 0.001) {
      console.log(`POS ${spec.id}[${index}] plan=${spec.position[index]} layout=${placed.position[index]}`)
      bad += 1
    }
  }
  if (placed.scale.some(value => Math.abs(value - 1) > 1e-9)) { console.log(`SCALE ${spec.id}`); bad += 1 }
}
const groups = layout.groups.map(group => group.name)
if (JSON.stringify(groups) !== JSON.stringify(['Terrain', 'Buildings', 'Props'])) {
  console.log(`GROUPS ${JSON.stringify(groups)}`); bad += 1
}
if (layout.root !== `${plan.sceneName}_Root`) { console.log(`ROOT ${layout.root}`); bad += 1 }
process.exit(bad === 0 ? 0 : 1)
JS
if node "$WORK/check-layout.mjs" "$WORK/layout.json" "$WORK/plan.json" >"$WORK/check-layout.log" 2>&1; then
  ok "11 个对象坐标与 plan 完全一致"
else
  bad "layout 坐标不一致"
  cat "$WORK/check-layout.log"
fi

echo "[5] scene.fbx 重导入：层级与实例名"
cat >"$WORK/verify-fbx.py" <<'PY'
import bpy, json, sys
fbx, layout_path = sys.argv[sys.argv.index("--") + 1], sys.argv[sys.argv.index("--") + 2]
layout = json.load(open(layout_path))
root = layout["root"]
groups = [group["name"] for group in layout["groups"]]
instances = {obj["instanceName"] for group in layout["groups"] for obj in group["objects"]}
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=fbx)
objs = {obj.name: obj for obj in bpy.data.objects}
errors = []
if root not in objs:
    errors.append(f"缺少 root：{root}")
else:
    children = {child.name for child in objs[root].children}
    for group in groups:
        if group not in children:
            errors.append(f"root 下缺少分组：{group}")
for group_name in groups:
    group = objs.get(group_name)
    if group is None:
        errors.append(f"缺少分组 Empty：{group_name}")
missing = sorted(name for name in instances if name not in objs)
if missing:
    errors.append(f"缺少实例节点：{missing[:6]}")
print("FBX_OK" if not errors else "FBX_ERR " + "; ".join(errors))
PY
if "$BLENDER" --background --factory-startup --python "$WORK/verify-fbx.py" -- "$WORK/scene.fbx" "$WORK/layout.json" >"$WORK/fbx.log" 2>&1 \
  && grep -q 'FBX_OK' "$WORK/fbx.log"; then
  ok "fbx 含 root / 3 个分组 / 11 个实例节点"
else
  bad "fbx 层级断言失败"
  grep -E 'FBX_(OK|ERR)' "$WORK/fbx.log" | tail -2
fi

echo "[6] 非法 plan 让 Blender 拒绝执行"
"$BLENDER" --background --factory-startup \
  --python "$PLUGIN_DIR/lib/scripts/run_scenic.py" -- \
  "$PLUGIN_DIR/lib/scripts/scenes/courtyard.py" \
  "$WORK/bad.blend" "$WORK/bad.glb" "$WORK/bad.fbx" "$WORK/bad.json" \
  "{\"sceneSource\":\"llm\",\"layoutObjects\":\"$WORK/bad-overlap.json\"}" >"$WORK/bad.log" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "非法 plan 退出码非 0（exit=${rc}）" || bad "非法 plan 仍然成功执行"
check "错误信息含「布局校验失败」" "grep -q '布局校验失败' '$WORK/bad.log'"
check "未生成 layout.json" "[ ! -s '$WORK/bad.json' ]"

echo "[7] 宿主接线：plan 工具注册 + /state 配置字段"
DSH_BIN="${DSH_BIN:-dsh}"
DSH_HOME="$ROOT/.dsh-dev" "$DSH_BIN" --profile web --patch "$ROOT/scratch-plugin/cordis.yml" --no-open --port 0 >"$HOST_LOG" 2>&1 &
HOST_PID=$!
URL=""
for _ in $(seq 1 120); do
  if ! kill -0 "$HOST_PID" 2>/dev/null; then break; fi
  URL=$(grep -Eo 'http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+' "$HOST_LOG" | head -1)
  [ -n "$URL" ] && break
  sleep 0.5
done
check "插件加载日志" "grep -q 'dsh-scene-skeleton-pipeline] loaded' '$HOST_LOG'"
check "plan 工具注册日志" "grep -q 'plan tool registered: plan_scene_layout' '$HOST_LOG'"
if [ -n "$URL" ]; then
  JAR="$WORK/jar.txt"
  curl -s -c "$JAR" -L "$URL" -o /dev/null || true
  STATE=$(curl -s -b "$JAR" "${URL%%/?*}" 2>/dev/null || true)
  BASE="${URL%%/\?*}"
  STATE=$(curl -s -b "$JAR" "$BASE/plugins/dsh-scene-skeleton-pipeline/state" 2>/dev/null || true)
  printf '%s' "$STATE" >"$WORK/state.json"
  check "/state 含 sceneSource" "grep -q '\"sceneSource\"' '$WORK/state.json'"
  check "/state 含 layoutObjects" "grep -q '\"layoutObjects\"' '$WORK/state.json'"
  check "/state sceneSource=template（默认）" "grep -q '\"sceneSource\": \"template\"' '$WORK/state.json'"
else
  bad "宿主没有输出 token URL"
fi

echo ""
echo "==============================="
echo "verify-layout-llm: PASS=$PASS FAIL=$FAIL"
echo "==============================="
[ "$FAIL" -eq 0 ]
