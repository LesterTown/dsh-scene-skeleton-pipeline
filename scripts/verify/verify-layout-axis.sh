#!/usr/bin/env bash
# ============================================================================
# 阶段 7 补丁验证：layoutAxis（z-up / y-up）端到端
# ----------------------------------------------------------------------------
# 用法：
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-layout-axis.sh
#
# 不需要 ComfyUI / Unity：
#   [1] layout-axis-probe.mjs：template / llm 两种来源下 z-up 与 y-up 的
#       axis 字段、root/groups/objectCount、相机与对象坐标的 (x,y,z)↔(x,z,-y)
#       关系、adapter 转换与 Blender 直出一致、summary.layoutAxis、非法 axis 被拒
#   [2] 抽查 .blend：z-up 模式下 layout 相机坐标 == Blender 场景里的实际相机坐标
#   [3] 宿主接线：/state 默认 layoutAxis=z-up；POST /config 改成 y-up 后
#       /state 与持久化配置文件都变为 y-up
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

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

WORK="$(mktemp -d /tmp/dsh-layout-axis.XXXXXX)"
HOST_PID=""
CONFIG_FILE="$ROOT/.dsh-dev/scene-skeleton-pipeline/config.json"
CONFIG_BAK=""
cleanup() {
  [ -n "$HOST_PID" ] && kill "$HOST_PID" 2>/dev/null || true
  rm -rf "$WORK"
  if [ -n "$CONFIG_BAK" ] && [ -f "$CONFIG_BAK" ]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    mv -f "$CONFIG_BAK" "$CONFIG_FILE"
  fi
}
trap cleanup EXIT

echo "[1] layout-axis-probe.mjs（template / llm × z-up / y-up + adapter 转换）"
PROBE_OUT="$WORK/probe.log"
if node "$PLUGIN_DIR/scripts/verify/layout-axis-probe.mjs" "$WORK/probe" >"$PROBE_OUT" 2>&1; then
  probe_line=$(grep -E '^probe: PASS=' "$PROBE_OUT" | tail -1)
  [ -n "$probe_line" ] && ok "$probe_line" || bad "probe 没有输出汇总行"
else
  bad "probe 退出码非 0"
  tail -10 "$PROBE_OUT" | sed 's/^/       /'
fi

echo "[2] z-up 模式下 layout 相机坐标 == Blender 场景实际相机坐标"
"$BLENDER" --background --factory-startup \
  --python "$PLUGIN_DIR/lib/scripts/run_scenic.py" -- \
  "$PLUGIN_DIR/lib/scripts/scenes/courtyard.py" \
  "$WORK/zup/scene.blend" "$WORK/zup/scene.glb" "$WORK/zup/scene.fbx" "$WORK/zup/layout.json" \
  '{"seed":42,"layoutAxis":"z-up"}' >"$WORK/zup.log" 2>&1
check "run_scenic.py（z-up）生成 .blend/.layout.json" "[ -s '$WORK/zup/scene.blend' ] && [ -s '$WORK/zup/layout.json' ]"
cat >"$WORK/camera-check.py" <<'PY'
import bpy, json, sys
blend_layout = json.load(open(sys.argv[sys.argv.index("--") + 1]))
camera_name = (blend_layout.get("camera") or {}).get("name") or "SceneSkeleton_Camera"
obj = bpy.data.objects.get(camera_name)
expected = blend_layout["camera"]["position"]
ok = obj is not None and all(abs(obj.location[i] - expected[i]) <= 0.01 for i in range(3))
print("CAMERA_CHECK:" + ("OK" if ok else "FAIL") +
      " actual=%s expected=%s" % (None if obj is None else list(obj.location), expected))
PY
"$BLENDER" --background "$WORK/zup/scene.blend" --python "$WORK/camera-check.py" -- "$WORK/zup/layout.json" \
  >"$WORK/camera-check.log" 2>&1
check "layout.camera.position 与 Blender 内相机一致" "grep -q 'CAMERA_CHECK:OK' '$WORK/camera-check.log'"

echo "[3] 宿主接线：默认 z-up；改配置后 y-up 生效并持久化"
mkdir -p "$(dirname "$CONFIG_FILE")"
if [ -f "$CONFIG_FILE" ]; then
  CONFIG_BAK="$WORK/config.json.bak"
  cp "$CONFIG_FILE" "$CONFIG_BAK"
  rm -f "$CONFIG_FILE"
fi
HOST_LOG="$WORK/host.log"
DSH_BIN="${DSH_BIN:-dsh}"
DSH_HOME="$ROOT/.dsh-dev" "$DSH_BIN" --profile web --patch "$ROOT/scratch-plugin/cordis.yml" --no-open --port 0 >"$HOST_LOG" 2>&1 &
HOST_PID=$!
URL=""
for _ in $(seq 1 120); do
  kill -0 "$HOST_PID" 2>/dev/null || break
  URL=$(grep -Eo 'http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+' "$HOST_LOG" | head -1)
  [ -n "$URL" ] && break
  sleep 0.5
done
check "插件加载日志" "grep -q 'dsh-scene-skeleton-pipeline] loaded' '$HOST_LOG'"
if [ -n "$URL" ]; then
  BASE="${URL%%/\?*}"
  JAR="$WORK/jar.txt"
  curl -s -c "$JAR" -L "$URL" -o /dev/null || true
  STATE="$WORK/state-zup.json"
  curl -s -b "$JAR" "$BASE/plugins/dsh-scene-skeleton-pipeline/state" >"$STATE" 2>/dev/null || true
  check "/state 默认 layoutAxis=z-up" "grep -q '\"layoutAxis\": \"z-up\"' '$STATE'"
  SAVE="$WORK/save.json"
  curl -s -b "$JAR" -X POST "$BASE/plugins/dsh-scene-skeleton-pipeline/config" \
    -H 'content-type: application/json' \
    -d '{"layoutAxis":"y-up"}' >"$SAVE" 2>/dev/null || true
  check "/config 保存 layoutAxis=y-up" "grep -q '\"saved\": true' '$SAVE'"
  STATE2="$WORK/state-yup.json"
  curl -s -b "$JAR" "$BASE/plugins/dsh-scene-skeleton-pipeline/state" >"$STATE2" 2>/dev/null || true
  check "/state 反映 layoutAxis=y-up" "grep -q '\"layoutAxis\": \"y-up\"' '$STATE2'"
  check "配置文件持久化 y-up" "grep -q '\"layoutAxis\": \"y-up\"' '$CONFIG_FILE'"
  curl -s -b "$JAR" "$BASE/" -o "$WORK/index.html" 2>/dev/null || true
  HREF=$(python3 - "$WORK/index.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding='utf-8').read()
hrefs = re.findall(r'href="(plugins/\?\?[^"]*dsh-scene-skeleton-pipeline/client\.js[^"]*)"', html)
print((hrefs[0] if hrefs else '').replace('&amp;', '&'))
PY
)
  if [ -n "$HREF" ]; then
    curl -s -b "$JAR" "$BASE/$HREF" -o "$WORK/client-bundle.js" 2>/dev/null || true
    check "client bundle 含 layoutAxis 文案" "grep -q 'layoutAxis' '$WORK/client-bundle.js'"
  else
    bad "index.html 里找不到 client bundle URL"
  fi
else
  bad "宿主没有输出 token URL"
fi

echo ""
echo "==============================="
echo "verify-layout-axis: PASS=$PASS FAIL=$FAIL"
echo "==============================="
[ "$FAIL" -eq 0 ]
