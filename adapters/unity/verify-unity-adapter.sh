#!/usr/bin/env bash
#
# Unity 适配器验收脚本（阶段 5 之后从 verify-step4/5/6 迁移而来）。
#
# 流水线的核心产物是引擎无关的 Blender 场景骨架（scene.blend/.fbx/.glb + layout.json）；
# Unity 只是可选适配器（enableUnityAdapter，默认关闭）。因此 Unity 相关的断言都集中在这里，
# 默认不参与核心回归（verify-step2..6 与 verify-blender-export / verify-layout-axis /
# verify-layout-llm 不依赖 Unity）。
#
# 用法：
#   bash dsh-scene-skeleton-pipeline/adapters/unity/verify-unity-adapter.sh            # 按当前配置；未启用则 SKIP
#   bash dsh-scene-skeleton-pipeline/adapters/unity/verify-unity-adapter.sh --force    # 强制跑适配器断言（会覆盖本次配置）
#   bash dsh-scene-skeleton-pipeline/adapters/unity/verify-unity-adapter.sh --skip-real # 只验证宿主接线
#
# 前提：
#   - 本机 ComfyUI 已在 http://127.0.0.1:8188 运行
#   - 一个真实 Unity 工程（默认 .dsh-dev/unity-e2e-project；可用 UNITY_PROJECT= 指定）
#   - Blender 可执行（默认 /Applications/Blender.app/Contents/MacOS/Blender）
#
# 覆盖（原先散落在 verify-step4/5/6 的 Unity 断言）：
#   A. 宿主接线：enableUnityAdapter=true 时 /state.pipeline 有 3 个节点、unity 环境 ok、dry-run 三节点全 ok
#   B. legacy 真实执行：job done、三节点 ok、产物 image/blend/mesh(fbx)/scene 存在、unity-result.json success、
#      场景文件含 fbx 实例与 Main Camera
#   C. scenic 真实执行：unity-result.json success / objectCount>=5 / groups 含 Terrain+Buildings+Props、
#      场景文件存在、世界包围盒尺寸是米制（防 100 倍缩放回归）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
PATCH="$ROOT/scratch-plugin/cordis.yml"
DEV_HOME="$ROOT/.dsh-dev"
BASE_PATH="/plugins/dsh-scene-skeleton-pipeline"
CONFIG_FILE="$DEV_HOME/scene-skeleton-pipeline/config.json"
UNITY_PROJECT="${UNITY_PROJECT:-$DEV_HOME/unity-e2e-project}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/dsh-scene-e2e-unity-adapter}"
COMFY_URL="${COMFY_URL:-http://127.0.0.1:8188}"
CHECKPOINT="${CHECKPOINT:-DreamShaper_8_pruned.safetensors}"

FORCE=0
REAL=1
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --skip-real) REAL=0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done
[ "${DSH_FORCE_UNITY_ADAPTER:-0}" = "1" ] && FORCE=1

# ------------------------------------------------------- 0. 适配器是否启用
configured=0
if [ -f "$CONFIG_FILE" ]; then
  configured=$(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print(0); raise SystemExit
value = data.get('enableUnityAdapter', False)
print(1 if value is True or str(value).lower() == 'true' else 0)
PY
)
fi

if [ "$configured" != "1" ] && [ "$FORCE" != "1" ]; then
  echo 'SKIP: Unity adapter disabled'
  echo "（配置 $CONFIG_FILE 里 enableUnityAdapter=false；用 --force 或 DSH_FORCE_UNITY_ADAPTER=1 强制跑）"
  exit 0
fi

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()
TMP="$(mktemp -d -t dsh-unity-adapter.XXXXXX)"
HOST_PID=""
LOG_FILE=""
JAR=""
BASE=""

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}"; }
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$name"; else fail "$name" "expected [$expected] got [$actual]"; fi
}
json_get() { python3 -c "import json,sys;d=json.load(open('$1'));print($2)"; }

cleanup() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  [ -n "$LOG_FILE" ] && rm -f "$LOG_FILE"
  [ -n "$JAR" ] && rm -f "$JAR"
  rm -rf "$TMP"
}
trap cleanup EXIT

boot_host() {
  LOG_FILE="$(mktemp -t dsh-unity-adapter-host.XXXXXX)"
  JAR="$(mktemp -t dsh-unity-adapter-jar.XXXXXX)"
  DSH_HOME="$DEV_HOME" dsh --profile web --patch "$PATCH" --no-open --port 0 >"$LOG_FILE" 2>&1 &
  HOST_PID=$!
  local token_url=""
  for _ in $(seq 1 160); do
    token_url=$(grep -o 'http://127.0.0.1:[0-9]*/?token=[A-Za-z0-9_-]*' "$LOG_FILE" | head -1)
    [ -n "$token_url" ] && break
    if ! kill -0 "$HOST_PID" 2>/dev/null; then
      echo '--- host log ---'; cat "$LOG_FILE"; return 1
    fi
    sleep 0.5
  done
  if [ -z "$token_url" ]; then
    echo '--- host log（没等到 dsh web URL）---'; cat "$LOG_FILE"; return 1
  fi
  BASE="${token_url%%/?token=*}"
  curl -sS -c "$JAR" -L "$token_url" -o /dev/null || return 1
  return 0
}

stop_host() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  HOST_PID=""
  [ -n "$JAR" ] && rm -f "$JAR"
  JAR=""
}

api() { curl -sS -b "$JAR" -m 60 "$BASE$BASE_PATH$1" "${@:2}"; }

# ---------------------------------------------------------------- 0. 前置条件
echo '== 0. 前置条件（Unity 适配器）=='
comfy_code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$COMFY_URL/queue" 2>/dev/null || true)"
[ "$comfy_code" = "200" ] && pass "ComfyUI 可达（$COMFY_URL/queue → 200）" \
  || fail "ComfyUI 不可达（$COMFY_URL/queue → ${comfy_code:-连接失败}）" '请先启动 ComfyUI 再跑本脚本'
[ -f "$UNITY_PROJECT/ProjectSettings/ProjectVersion.txt" ] && pass "Unity 工程存在（${UNITY_PROJECT}）" \
  || fail "Unity 工程不存在（${UNITY_PROJECT}）" '用 UNITY_PROJECT=<path> 指定真实工程'
[ -x /Applications/Blender.app/Contents/MacOS/Blender ] && pass 'Blender 可执行存在' \
  || fail 'Blender 可执行不存在' '/Applications/Blender.app/Contents/MacOS/Blender'

[ "$FAIL" = "0" ] || { echo; echo "前置条件不满足，终止。"; exit 1; }

# ---------------------------------------------------------------- A. 宿主接线
echo
echo '== A. 宿主接线（enableUnityAdapter=true）=='
rm -f "$CONFIG_FILE"
if ! boot_host; then
  fail '宿主启动' '见上方日志'
  echo; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

grep -q 'pipeline engine ready: comfy -> blender' "$LOG_FILE" \
  && pass '加载日志含 pipeline engine ready' || fail '缺少 pipeline engine ready 日志'

config_body=$(python3 -c 'import json,sys;print(json.dumps({"comfyUrl":sys.argv[1],"comfyCheckpoint":sys.argv[2],"unityProjectPath":sys.argv[3],"outputDir":sys.argv[4],"enableUnityAdapter":True}))' \
  "$COMFY_URL" "$CHECKPOINT" "$UNITY_PROJECT" "$OUTPUT_DIR")
api /config -X POST -H 'content-type: application/json' -d "$config_body" >"$TMP/config.json" 2>&1

assert_eq '/config 保存成功' 'True' "$(json_get "$TMP/config.json" "d['saved']")"
assert_eq '环境 unity' 'ok' "$(json_get "$TMP/config.json" "d['environment']['unity']['status']")"
assert_eq '流水线节点数（含适配器）' '3' "$(json_get "$TMP/config.json" "len(d['pipeline']['stages'])")"

api /pipeline/run -X POST -H 'content-type: application/json' \
  -d '{"prompt":"a quiet stone courtyard with a watchtower","dryRun":true}' >"$TMP/dry.json" 2>&1
assert_eq 'dry-run job done' 'done' "$(json_get "$TMP/dry.json" "d['job']['status']")"
assert_eq 'dry-run 三个节点全 ok' 'True' \
  "$(json_get "$TMP/dry.json" "all(s['status']=='ok' for s in d['job']['stages'])")"

stop_host
rm -f "$CONFIG_FILE"

# ---------------------------------------------------------------- B. legacy 真实执行
if [ "$REAL" != "1" ]; then
  echo
  echo '== B/C. 真实执行：已跳过（--skip-real）=='
else
  echo
  echo '== B. legacy 真实执行（ComfyUI → Blender → Unity，约 3-5 分钟）=='
  rm -rf "$OUTPUT_DIR"
  DSH_UNITY_ADAPTER=1 node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" "$UNITY_PROJECT" "$OUTPUT_DIR" '' legacy \
    >"$TMP/legacy.log" 2>&1 \
    && pass 'legacy real-e2e.mjs exit 0' \
    || { fail 'legacy real-e2e.mjs 失败' "见 $TMP/legacy.log"; tail -25 "$TMP/legacy.log"; }

  if [ -f "$OUTPUT_DIR/last-job.json" ]; then
    assert_eq 'legacy job done' 'done' "$(json_get "$OUTPUT_DIR/last-job.json" "d['status']")"
    assert_eq 'legacy 三个节点全 ok' 'True' \
      "$(json_get "$OUTPUT_DIR/last-job.json" "all(s['status']=='ok' for s in d['stages'])")"
    for kind in image blend mesh scene; do
      path=$(json_get "$OUTPUT_DIR/last-job.json" \
        "next((a['path'] for s in d['stages'] for a in s.get('artifacts',[]) if a.get('kind')=='$kind' and a.get('path')), '')")
      if [ -n "$path" ] && [ -f "$path" ] && [ -s "$path" ]; then
        pass "legacy 产物 $kind 存在且非空（$(basename "$path")，$(wc -c <"$path" | tr -d ' ') 字节）"
      else
        fail "legacy 产物 $kind 缺失或为空" "${path:-（job 里没有该 kind 的路径）}"
      fi
    done

    unity_result=$(json_get "$OUTPUT_DIR/last-job.json" \
      "next((s.get('report',{}).get('unityResultPath','') for s in d['stages'] if s['id']=='unity'), '')")
    if [ -n "$unity_result" ] && [ -f "$unity_result" ]; then
      assert_eq 'unity-result.json success' 'True' "$(json_get "$unity_result" "d['success']")"
      assert_eq 'unity-result scenePath 以 .unity 结尾' 'True' \
        "$(json_get "$unity_result" "d['scenePath'].endswith('.unity')")"
      assert_eq 'unity-result objectCount >= 2' 'True' "$(json_get "$unity_result" "d['objectCount'] >= 2")"
    else
      fail 'unity-result.json 不存在' "${unity_result:-（job 里没有 unity 阶段 report）}"
    fi

    scene_path=$(json_get "$OUTPUT_DIR/last-job.json" \
      "next((a['path'] for s in d['stages'] for a in s.get('artifacts',[]) if a.get('kind')=='scene' and a.get('path')), '')")
    if [ -n "$scene_path" ] && grep -q 'PrefabInstance' "$scene_path" && grep -q 'Main Camera' "$scene_path"; then
      pass '.unity 场景包含 fbx 实例与 Main Camera'
    else
      fail '.unity 场景内容异常' "${scene_path:-（无场景路径）}"
    fi
  else
    fail 'legacy last-job.json 不存在' '真实执行没有产出 job 记录'
  fi

  # ------------------------------------------------------------ C. scenic 真实执行 + 尺寸回归
  echo
  echo '== C. scenic 真实执行 + 世界尺寸回归（防 100 倍缩放）=='
  SCENIC_OUT="${OUTPUT_DIR}-scenic"
  rm -rf "$SCENIC_OUT"
  BOUNDS="$TMP/bounds.txt"
  rm -f "$BOUNDS"
  DSH_UNITY_ADAPTER=1 DSH_UNITY_BOUNDS_OUT="$BOUNDS" \
    node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" "$UNITY_PROJECT" "$SCENIC_OUT" '' scenic \
    >"$TMP/scenic.log" 2>&1 \
    && pass 'scenic real-e2e.mjs exit 0' \
    || { fail 'scenic real-e2e.mjs 失败' "见 $TMP/scenic.log"; tail -25 "$TMP/scenic.log"; }

  if [ -f "$SCENIC_OUT/last-job.json" ]; then
    assert_eq 'scenic job done' 'done' "$(json_get "$SCENIC_OUT/last-job.json" "d['status']")"
    unity_result=$(json_get "$SCENIC_OUT/last-job.json" \
      "next((s.get('report',{}).get('unityResultPath','') for s in d['stages'] if s['id']=='unity'), '')")
    if [ -n "$unity_result" ] && [ -f "$unity_result" ]; then
      assert_eq 'scenic unity-result success' 'True' "$(json_get "$unity_result" "d['success']")"
      assert_eq 'scenic unity-result objectCount >= 5' 'True' "$(json_get "$unity_result" "d['objectCount'] >= 5")"
      assert_eq 'scenic unity-result groups 含 Terrain' 'True' \
        "$(json_get "$unity_result" "'Terrain' in d['groups']")"
      assert_eq 'scenic unity-result groups 含 Buildings' 'True' \
        "$(json_get "$unity_result" "'Buildings' in d['groups']")"
      assert_eq 'scenic unity-result groups 含 Props' 'True' \
        "$(json_get "$unity_result" "'Props' in d['groups']")"
      scene=$(json_get "$unity_result" "d['scenePath']")
      [ -f "$UNITY_PROJECT/$scene" ] && pass "scenic 场景文件存在（${scene}）" \
        || fail 'scenic 场景文件不存在' "$UNITY_PROJECT/$scene"
    else
      fail 'scenic unity-result.json 不存在' "${unity_result:-（job 里没有 unity 阶段 report）}"
    fi
  else
    fail 'scenic last-job.json 不存在' '真实执行没有产出 job 记录'
  fi

  # 世界包围盒：所有 Renderer 尺寸应在米制正常范围，且至少一个 > 5m（地面）
  if [ -s "$BOUNDS" ]; then
    check=$(python3 - "$BOUNDS" <<'PY'
import sys
rows = []
for line in open(sys.argv[1], encoding='utf-8'):
    parts = line.strip().split('|')
    if len(parts) != 4:
        continue
    name, sx, sy, sz = parts[0], float(parts[1]), float(parts[2]), float(parts[3])
    rows.append((name, max(sx, sy, sz)))
tiny = [r for r in rows if r[1] < 0.02]
huge = [r for r in rows if r[1] > 120]
big = [r for r in rows if r[1] > 5]
if not rows:
    print('EMPTY')
elif tiny:
    print('TINY:' + ','.join(f'{n}={s:.3f}' for n, s in tiny[:3]))
elif huge:
    print('HUGE:' + ','.join(f'{n}={s:.1f}' for n, s in huge[:3]))
elif not big:
    print('NO_BIG')
else:
    print('OK:' + str(len(rows)))
PY
)
    case "$check" in
      OK:*) pass "世界包围盒是米制正常范围（renderers=$(echo "${check#OK:}")，最大 > 5m）" ;;
      TINY:*) fail '世界包围盒出现过小尺寸（疑似 100 倍缩小回归）' "${check#TINY:}" ;;
      HUGE:*) fail '世界包围盒出现过大的尺寸（疑似 100 倍放大回归）' "${check#HUGE:}" ;;
      NO_BIG) fail '没有任何 > 5m 的物体（地面缺失或整体缩放异常）' ;;
      EMPTY|*) fail '包围盒报告为空' "${BOUNDS}" ;;
    esac
  else
    fail '包围盒报告缺失' 'DSH_UNITY_BOUNDS_OUT 没有写出文件（Unity 侧未执行 bounds 钩子）'
  fi
fi

# ---------------------------------------------------------------- 收尾
rm -f "$CONFIG_FILE"
echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" != "0" ]; then
  printf '失败项:\n'
  for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
  exit 1
fi
echo 'Unity 适配器验收全部通过。'
